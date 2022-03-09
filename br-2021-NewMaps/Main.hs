{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -O0 #-}

module Main where

import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Data.DataFrames as BR
import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.ElectionTypes as ET
import qualified BlueRipple.Data.ModelingTypes as MT
import qualified BlueRipple.Data.ACS_PUMS as PUMS
import qualified BlueRipple.Data.DistrictOverlaps as DO
--import qualified BlueRipple.Data.CCES as CCES
--import qualified BlueRipple.Data.CPSVoterPUMS as CPS
import qualified BlueRipple.Data.Loaders as BR
import qualified BlueRipple.Data.CensusTables as BRC
import qualified BlueRipple.Data.Loaders.Redistricting as Redistrict
import qualified BlueRipple.Data.Visualizations.DemoComparison as BRV
import qualified BlueRipple.Utilities.KnitUtils as BR
--import qualified BlueRipple.Utilities.Heidi as BR
import qualified BlueRipple.Utilities.TableUtils as BR
import qualified BlueRipple.Model.House.ElectionResult as BRE
import qualified BlueRipple.Data.CensusLoaders as BRC
import qualified BlueRipple.Model.StanMRP as MRP
import qualified BlueRipple.Data.CountFolds as BRCF
--import qualified BlueRipple.Data.Keyed as BRK

import qualified Colonnade as C
import qualified Text.Blaze.Colonnade as C
import qualified Text.Blaze.Html5.Attributes   as BHA
import qualified Control.Foldl as FL
import qualified Control.Foldl.Statistics as FLS
import qualified Data.List as List
import qualified Data.IntMap as IM
import qualified Data.Map.Strict as M
import qualified Data.Monoid as Monoid
import Data.String.Here (here, i)
import qualified Data.Set as Set
import qualified Data.Text as T
import qualified Text.Printf as T
import qualified Text.Read  as T
import qualified Data.Time.Calendar            as Time
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vector as Vector
import qualified System.Console.CmdArgs as CmdArgs
import qualified Flat
import qualified Frames as F
import qualified Frames.Melt as F
import qualified Frames.Streamly.InCore as FI
import qualified Frames.MapReduce as FMR
import qualified Frames.Aggregation as FA
import qualified Frames.Folds as FF
--import qualified Frames.Heidi as FH
import qualified Frames.SimpleJoins as FJ
import qualified Frames.Serialize as FS
import qualified Frames.Transform  as FT
import qualified Graphics.Vega.VegaLite as GV
import qualified Graphics.Vega.VegaLite.Compat as FV
import qualified Frames.Visualization.VegaLite.Data as FVD

import qualified Relude.Extra as Extra

import qualified Graphics.Vega.VegaLite.Configuration as FV
import qualified Graphics.Vega.VegaLite.Heidi as HV

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as KC
import qualified Text.Pandoc.Error as Pandoc
import qualified Numeric
import qualified Path
import Path (Rel, Abs, Dir, File)

import qualified Stan.ModelConfig as SC
import qualified Stan.ModelBuilder.BuildingBlocks as SB
import qualified Stan.ModelBuilder.SumToZero as SB
import qualified Stan.Parameters as SP
import qualified Stan.Parameters.Massiv as SPM
import qualified CmdStan as CS
import qualified Data.Vinyl.Core as V
import qualified Stan.ModelBuilder as SB
import BlueRipple.Data.Loaders (stateAbbrCrosswalkLoader)
import qualified BlueRipple.Data.DistrictOverlaps as DO

yamlAuthor :: T.Text
yamlAuthor =
  [here|
- name: Adam Conner-Sax
- name: Frank David
|]

templateVars :: M.Map String String
templateVars =
  M.fromList
    [ ("lang", "English"),
      ("site-title", "Blue Ripple Politics"),
      ("home-url", "https://www.blueripplepolitics.org")
      --  , ("author"   , T.unpack yamlAuthor)
    ]

pandocTemplate = K.FullySpecifiedTemplatePath "pandoc-templates/blueripple_basic.html"


main :: IO ()
main = do
  cmdLine <- CmdArgs.cmdArgsRun BR.commandLine
  pandocWriterConfig <-
    K.mkPandocWriterConfig
      pandocTemplate
      templateVars
      K.mindocOptionsF
  let cacheDir = ".flat-kh-cache"
      knitConfig :: K.KnitConfig BR.SerializerC BR.CacheData Text =
        (K.defaultKnitConfig $ Just cacheDir)
          { K.outerLogPrefix = Just "2021-NewMaps"
          , K.logIf = BR.knitLogSeverity $ BR.logLevel cmdLine --K.logDiagnostic
          , K.pandocWriterConfig = pandocWriterConfig
          , K.serializeDict = BR.flatSerializeDict
          , K.persistCache = KC.persistStrictByteString (\t -> toString (cacheDir <> "/" <> t))
          }
  let stanParallelCfg = BR.clStanParallel cmdLine
      parallel =  case BR.cores stanParallelCfg of
        BR.MaxCores -> True
        BR.FixedCores n -> n > BR.parallelChains stanParallelCfg
  resE <- K.knitHtmls knitConfig $ do
    K.logLE K.Info $ "Command Line: " <> show cmdLine
--    modelDetails cmdLine
    modelDiagnostics cmdLine --stanParallelCfg parallel
    newCongressionalMapPosts cmdLine --stanParallelCfg parallel
    newStateLegMapPosts cmdLine --stanParallelCfg parallel

  case resE of
    Right namedDocs ->
      K.writeAllPandocResultsWithInfoAsHtml "" namedDocs
    Left err -> putTextLn $ "Pandoc Error: " <> Pandoc.renderError err

modelDir :: Text
modelDir = "br-2021-NewMaps/stanDM5"
--dmModel = BRE.Model ET.TwoPartyShare (one ET.President) BRE.LogDensity
modelVariant = BRE.Model ET.TwoPartyShare (one ET.President) (BRE.BinDensity 10 5)

--emptyRel = [Path.reldir||]
postDir = [Path.reldir|br-2021-NewMaps/posts|]
postInputs p = postDir BR.</> p BR.</> [Path.reldir|inputs|]
postLocalDraft p mRSD = case mRSD of
  Nothing -> postDir BR.</> p BR.</> [Path.reldir|draft|]
  Just rsd -> postDir BR.</> p BR.</> rsd
postOnline p =  [Path.reldir|research/NewMaps|] BR.</> p
postOnlineExp p = [Path.reldir|explainer/model|] BR.</> p

postPaths :: (K.KnitEffects r, MonadIO (K.Sem r))
          => Text
          -> BR.CommandLine
          -> K.Sem r (BR.PostPaths BR.Abs)
postPaths t cmdLine = do
  let mRelSubDir = case cmdLine of
        BR.CLLocalDraft _ _ mS -> maybe Nothing BR.parseRelDir $ fmap toString mS
        _ -> Nothing
  postSpecificP <- K.knitEither $ first show $ Path.parseRelDir $ toString t
  BR.postPaths
    BR.defaultLocalRoot
    (postInputs postSpecificP)
    (postLocalDraft postSpecificP mRelSubDir)
    (postOnline postSpecificP)

explainerPostPaths :: (K.KnitEffects r, MonadIO (K.Sem r))
                   => Text
                   -> BR.CommandLine
                   -> K.Sem r (BR.PostPaths BR.Abs)
explainerPostPaths t cmdLine = do
  let mRelSubDir = case cmdLine of
        BR.CLLocalDraft _ _ mS -> maybe Nothing BR.parseRelDir $ fmap toString mS
        _ -> Nothing
  postSpecificP <- K.knitEither $ first show $ Path.parseRelDir $ toString t
  BR.postPaths
    BR.defaultLocalRoot
    (postInputs postSpecificP)
    (postLocalDraft postSpecificP mRelSubDir)
    (postOnlineExp postSpecificP)


-- data
type CCESVoted = "CCESVoters" F.:-> Int
type CCESHouseVotes = "CCESHouseVotes" F.:-> Int
type CCESHouseDVotes = "CCESHouseDVotes" F.:-> Int

type PredictorR = [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC]

type CDDemographicsR = '[BR.StateAbbreviation] V.++ BRC.CensusRecodedR V.++ '[DT.Race5C]
type CDLocWStAbbrR = '[BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber] -- V.++ BRC.LDLocationR

filterCcesAndPumsByYear :: (Int -> Bool) -> BRE.CCESAndPUMS -> BRE.CCESAndPUMS
filterCcesAndPumsByYear f (BRE.CCESAndPUMS cces cps pums dd) = BRE.CCESAndPUMS (q cces) (q cps) (q pums) (q dd) where
  q :: (F.ElemOf rs BR.Year, FI.RecVec rs) => F.FrameRec rs -> F.FrameRec rs
  q = F.filterFrame (f . F.rgetField @BR.Year)

aggregatePredictorsCDFld fldData = FMR.concatFold
                                   $ FMR.mapReduceFold
                                   FMR.noUnpack
                                   (FMR.assignKeysAndData @[BR.Year, DT.StateAbbreviation, ET.CongressionalDistrict])
                                   (FMR.foldAndAddKey fldData)

aggregatePredictorsCountyFld fldData = FMR.concatFold
                                       $ FMR.mapReduceFold
                                       FMR.noUnpack
                                       (FMR.assignKeysAndData @[BR.Year, DT.StateAbbreviation, BR.CountyFIPS])
                                       (FMR.foldAndAddKey fldData)

debugCES :: K.KnitEffects r => F.FrameRec BRE.CCESByCDR -> K.Sem r ()
debugCES ces = do
  let aggFld :: FL.Fold (F.Record BRE.CCESVotingDataR) (F.Record BRE.CCESVotingDataR)
      aggFld = FF.foldAllConstrained @Num FL.sum
      genderFld = FMR.concatFold
                  $ FMR.mapReduceFold
                  FMR.noUnpack
                  (FMR.assignKeysAndData @[BR.Year, DT.SexC])
                  (FMR.foldAndAddKey aggFld)
      cesByYearAndGender = FL.fold genderFld ces
  BR.logFrame cesByYearAndGender

debugPUMS :: K.KnitEffects r => F.FrameRec BRE.PUMSByCDR -> K.Sem r ()
debugPUMS pums = do
  let aggFld :: FL.Fold (F.Record '[PUMS.Citizens, PUMS.NonCitizens]) (F.Record '[PUMS.Citizens, PUMS.NonCitizens])
      aggFld = FF.foldAllConstrained @Num FL.sum
      raceFld = FMR.concatFold
                  $ FMR.mapReduceFold
                  FMR.noUnpack
                  (FMR.assignKeysAndData @[BR.Year, DT.RaceAlone4C, DT.HispC])
                  (FMR.foldAndAddKey aggFld)
      pumsByYearAndRace = FL.fold raceFld pums
  BR.logFrame pumsByYearAndRace

{-
showVACPS :: (K.KnitEffects r, BR.CacheEffects r) => F.FrameRec BRE.CPSVByCDR -> K.Sem r ()
showVACPS cps = do
  let cps2020VA = F.filterFrame (\r -> F.rgetField @BR.Year r == 2020 && F.rgetField @BR.StateAbbreviation r == "VA") cps
      nVA = FL.fold (FL.premap (F.rgetField @BRCF.Count) FL.sum) cps2020VA
      nVoted = FL.fold (FL.premap (F.rgetField @BRCF.Successes) FL.sum) cps2020VA
  K.logLE K.Info $ "CPS VA: " <> show nVA <> " rows and " <> show nVoted <> " voters."
  let aggFld :: FL.Fold (F.Record [BRCF.Count, BRCF.Successes]) (F.Record [BRCF.Count, BRCF.Successes])
      aggFld = FF.foldAllConstrained @Num FL.sum
      aggregated = FL.fold (aggregatePredictorsCDFld aggFld) cps2020VA
  BR.logFrame aggregated
  cpsRaw <- K.ignoreCacheTimeM CPS.cpsVoterPUMSLoader
  let cpsRaw2020VA = F.filterFrame (\r -> F.rgetField @BR.Year r == 2020 && F.rgetField @BR.StateAbbreviation r == "VA") cpsRaw
      aFld :: FL.Fold (F.Record '[CPS.CPSVoterPUMSWeight]) (F.Record '[CPS.CPSVoterPUMSWeight])
      aFld = FF.foldAllConstrained @Num FL.sum
      aggregatedRaw = FL.fold (aggregatePredictorsCountyFld aFld) cpsRaw
  BR.logFrame aggregatedRaw
-}
onlyState :: (F.ElemOf xs BR.StateAbbreviation, FI.RecVec xs) => Text -> F.FrameRec xs -> F.FrameRec xs
onlyState stateAbbr = F.filterFrame ((== stateAbbr) . F.rgetField @BR.StateAbbreviation)

prepCensusDistrictData :: (K.KnitEffects r, BR.CacheEffects r)
                   => Bool
                   -> Text
                   -> K.ActionWithCacheTime r BRC.LoadedCensusTablesByLD
                   -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec CDDemographicsR))
prepCensusDistrictData clearCaches cacheKey cdData_C = do
  stateAbbreviations <-  BR.stateAbbrCrosswalkLoader
  let deps = (,) <$> cdData_C <*> stateAbbreviations
  when clearCaches $ BR.clearIfPresentD cacheKey
  BR.retrieveOrMakeFrame cacheKey deps $ \(cdData, stateAbbrs) -> do
    let addRace5 = FT.mutate (\r -> FT.recordSingleton @DT.Race5C
                                    $ DT.race5FromRaceAlone4AndHisp True (F.rgetField @DT.RaceAlone4C r) (F.rgetField @DT.HispC r))
        cdDataSER' = BRC.censusDemographicsRecode $ BRC.sexEducationRace cdData
        (cdDataSER, cdMissing) =  FJ.leftJoinWithMissing @'[BR.StateFips] cdDataSER'
                                  $ fmap (F.rcast @[BR.StateFips, BR.StateAbbreviation] . FT.retypeColumn @BR.StateFIPS @BR.StateFips) stateAbbrs
    when (not $ null cdMissing) $ K.knitError $ "state FIPS missing in proposed district demographics/stateAbbreviation join."
    return $ (F.rcast . addRace5 <$> cdDataSER)

modelDetails ::  forall r. (K.KnitMany r, BR.CacheEffects r) => BR.CommandLine -> K.Sem r () --BR.StanParallel -> Bool -> K.Sem r ()
modelDetails cmdLine = do
  let postInfoDetails = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes (BR.Published $ Time.fromGregorian 2021 9 23) (Just BR.Unpublished))
  detailsPaths <- explainerPostPaths "ElectionModel" cmdLine
  BR.brNewPost detailsPaths postInfoDetails "ElectionModel"
    $ BR.brAddPostMarkDownFromFile detailsPaths "_intro"

modelDiagnostics ::  forall r. (K.KnitMany r, BR.CacheEffects r) => BR.CommandLine -> K.Sem r () --BR.StanParallel -> Bool -> K.Sem r ()
modelDiagnostics cmdLine = do
  ccesAndPums_C <- BRE.prepCCESAndPums False
  ccesAndCPSEM_C <-  BRE.prepCCESAndCPSEM False
  acs_C <- BRE.prepACS False
  let ccesAndCPS2020_C = fmap (BRE.ccesAndCPSForYears [2020]) ccesAndCPSEM_C
      acs2020_C = fmap (BRE.acsForYears [2020]) acs_C
      ccesWD_C = fmap BRE.ccesEMRows ccesAndCPSEM_C
      elexRowsFilter r = F.rgetField @ET.Office r == ET.President && F.rgetField @BR.Year r == 2020
      presElex2020_C = fmap (F.filterFrame elexRowsFilter . BRE.stateElectionRows) $ ccesAndCPSEM_C
      stanParams = SC.StanMCParameters 4 4 (Just 1000) (Just 1000) (Just 0.8) (Just 10) Nothing
      mapGroup :: SB.GroupTypeTag (F.Record CDLocWStAbbrR) = SB.GroupTypeTag "CD"
      name = "Diagnostic"
      postStratInfo = (mapGroup
                      , "DM_Diagnostics_AllCDs"
                      , SB.addGroupToSet BRE.stateGroup SB.emptyGroupSet
                      )
      modelDM :: K.ActionWithCacheTime r (F.FrameRec PostStratR)
              -> K.Sem r (BRE.ModelCrossTabs, F.FrameRec (BRE.ModelResultsR CDLocWStAbbrR))
      modelDM x = do
        let gqDeps = (,) <$> acs2020_C <*> x
        K.ignoreCacheTimeM $ BRE.electionModelDM False cmdLine (Just stanParams) modelDir modelVariant 2020 postStratInfo ccesAndCPS2020_C gqDeps
      postInfoDiagnostics = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished (Just BR.Unpublished))
  (crossTabs, _) <- modelDM (fmap fixACS <$> acs2020_C)
  K.logLE K.Info $ BRE.dataLabel modelVariant <> " :By State"
  BR.logFrame $ BRE.byState crossTabs
  K.logLE K.Info $ BRE.dataLabel modelVariant <> ": By Race"
  BR.logFrame $ BRE.byRace crossTabs
  K.logLE K.Info $ BRE.dataLabel modelVariant <> ": By Sex"
  BR.logFrame $ BRE.bySex crossTabs
  K.logLE K.Info $ BRE.dataLabel modelVariant <> ": By Education"
  BR.logFrame $ BRE.byEducation crossTabs

  diag_C <- BRE.ccesDiagnostics False "DiagPost"
            (fmap (fmap F.rcast . BRE.pumsRows) ccesAndPums_C)
            (fmap (fmap F.rcast . BRE.ccesRows) ccesAndPums_C)
  ccesDiagByState <- K.ignoreCacheTime diag_C

  presElexByState <- K.ignoreCacheTime presElex2020_C
  let (diagTable1 , missingCTElex, missingCCES) = FJ.leftJoin3WithMissing @[BR.Year, BR.StateAbbreviation] (BRE.byState crossTabs) presElexByState ccesDiagByState
  when (not $ null missingCTElex) $ K.logLE K.Diagnostic $ "Missing keys in state crossTabs/presElex join: " <> show missingCTElex
  when (not $ null missingCCES) $ K.logLE K.Diagnostic $ "Missing keys in state crossTabs/presElex -> cces join: " <> show missingCCES
  stateTurnout <- fmap (F.rcast @[BR.Year, BR.StateAbbreviation, BR.BallotsCountedVEP, BR.HighestOfficeVEP, BR.VEP]) <$> K.ignoreCacheTimeM BR.stateTurnoutLoader
  cpsDiag <- K.ignoreCacheTimeM $ BRE.cpsDiagnostics "" $ fmap (fmap F.rcast . BRE.cpsVRows) ccesAndPums_C
  let cpsByState = snd cpsDiag
  let (diagTable2, missingTableTurnout, missingCPS) = FJ.leftJoin3WithMissing @[BR.Year, BR.StateAbbreviation] diagTable1 stateTurnout cpsByState
  when (not $ null missingTableTurnout) $ K.logLE K.Diagnostic $ "Missing keys when joining stateTurnout: " <> show missingTableTurnout
  when (not $ null missingCPS) $ K.logLE K.Diagnostic $ "Missing keys when joining CPS: " <> show missingCPS
  diagnosticsPaths <- postPaths "Diagnostics" cmdLine
  BR.brNewPost diagnosticsPaths postInfoDiagnostics "Diagnostics" $ do
    BR.brAddRawHtmlTable
      "By Race"
      (BHA.class_ "brTable")
      (byCategoryColonnade "Race" (show . F.rgetField @DT.Race5C) mempty)
      (BRE.byRace crossTabs)
    BR.brAddRawHtmlTable
      "By Sex"
      (BHA.class_ "brTable")
      (byCategoryColonnade "Sex" (show . F.rgetField @DT.SexC) mempty)
      (BRE.bySex crossTabs)
    BR.brAddRawHtmlTable
      "By Education"
      (BHA.class_ "brTable")
      (byCategoryColonnade "Education" (show . F.rgetField @DT.CollegeGradC) mempty)
      (BRE.byEducation crossTabs)
    BR.brAddRawHtmlTable
      "Diagnostics By State"
      (BHA.class_ "brTable")
      (diagTableColonnade mempty)
      diagTable2
    pure ()

byCategoryColonnade :: (F.ElemOf rs BRE.ModeledTurnout
                       , F.ElemOf rs BRE.ModeledPref
                       , F.ElemOf rs BRE.ModeledShare
                       )
                    => Text
                    -> (F.Record rs -> Text)
                    -> BR.CellStyle (F.Record rs) K.Cell
                    -> K.Colonnade K.Headed (F.Record rs) K.Cell
byCategoryColonnade catName f cas =
  let mTurnout = MT.ciMid . F.rgetField @BRE.ModeledTurnout
      mPref = MT.ciMid . F.rgetField @BRE.ModeledPref
      mShare = MT.ciMid . F.rgetField @BRE.ModeledShare
      mDiff r = let x = mShare r in (2 * x - 1)
  in  C.headed (BR.textToCell catName) (BR.toCell cas (BR.textToCell catName) catName (BR.textToStyledHtml . f))
      <> C.headed "Modeled Turnout" (BR.toCell cas "M Turnout" "M Turnout" (BR.numberToStyledHtml "%2.1f" . (100*) . mTurnout))
      <> C.headed "Modeled 2-party D Pref" (BR.toCell cas "M Share" "M Pref" (BR.numberToStyledHtml "%2.1f" . (100*) . mPref))
      <> C.headed "Modeled 2-party D Share" (BR.toCell cas "M Share" "M Share" (BR.numberToStyledHtml "%2.1f" . (100*) . mShare))
      <> C.headed "Modeled 2-party D Diff" (BR.toCell cas "M Diff" "M Diff" (BR.numberToStyledHtml "%2.1f" . (100*) . mDiff))

diagTableColonnade cas =
  let state = F.rgetField @DT.StateAbbreviation
      mTurnout = MT.ciMid . F.rgetField @BRE.ModeledTurnout
      mPref = MT.ciMid . F.rgetField @BRE.ModeledPref
      mShare = MT.ciMid . F.rgetField @BRE.ModeledShare
      mDiff r = let x = mShare r in (2 * x - 1)
      cvap = F.rgetField @PUMS.Citizens
      voters = F.rgetField @BRE.TVotes
      demVoters = F.rgetField @BRE.DVotes
      repVoters = F.rgetField @BRE.RVotes
      ratio x y = realToFrac @_ @Double x / realToFrac @_ @Double y
      rawTurnout r = ratio (voters r) (cvap r)
      ahTurnoutTarget = F.rgetField @BR.BallotsCountedVEP
      ccesTurnout  r = F.rgetField @BRE.AHVoted r / realToFrac (F.rgetField @ET.CVAP r)
      cpsTurnout r = ratio (F.rgetField @BRE.AHSuccesses r) (F.rgetField @BRCF.Count r)
      rawDShare r = ratio (demVoters r) (demVoters r + repVoters r)
      ccesDShare r = F.rgetField @BRE.AHPresDVotes r / realToFrac (F.rgetField @BRE.AHPresDVotes r + F.rgetField @BRE.AHPresRVotes r)
  in  C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
      <> C.headed "ACS CVAP" (BR.toCell cas "ACS CVAP" "ACS CVAP" (BR.numberToStyledHtml "%d" . cvap))
      <> C.headed "Elex Votes" (BR.toCell cas "Elex Votes" "Votes" (BR.numberToStyledHtml "%d" . voters))
      <> C.headed "Elex Dem Votes" (BR.toCell cas "Elex D Votes" "Elex D Votes" (BR.numberToStyledHtml "%d" . demVoters))
      <> C.headed "Elex Turnout" (BR.toCell cas "Elex Turnout" "Elex Turnout" (BR.numberToStyledHtml "%2.1f" . (100*) . rawTurnout))
      <> C.headed "AH Turnout Target" (BR.toCell cas "AH T Tgt" "AH T Tgt" (BR.numberToStyledHtml "%2.1f" . (100*) . ahTurnoutTarget))
      <> C.headed "CPS (PS) Turnout" (BR.toCell cas "CPS Turnout" "CPS Turnout" (BR.numberToStyledHtml "%2.1f" . (100*) . cpsTurnout))
      <> C.headed "CCES (PS) Turnout" (BR.toCell cas "CCES Turnout" "CCES Turnout" (BR.numberToStyledHtml "%2.1f" . (100*) . ccesTurnout))
      <> C.headed "Modeled Turnout" (BR.toCell cas "M Turnout" "M Turnout" (BR.numberToStyledHtml "%2.1f" . (100*) . mTurnout))
      <> C.headed "Raw 2-party D Share" (BR.toCell cas "Raw D Share" "Raw D Share" (BR.numberToStyledHtml "%2.1f" . (100*) . rawDShare))
      <> C.headed "CCES (PS) 2-party D Share" (BR.toCell cas "CCES D Share" "CCES D Share" (BR.numberToStyledHtml "%2.1f" . (100*) . ccesDShare))
      <> C.headed "Modeled 2-party D Pref" (BR.toCell cas "M Share" "M Share" (BR.numberToStyledHtml "%2.1f" . (100*) . mPref))
      <> C.headed "Modeled 2-party D Share" (BR.toCell cas "M Share" "M Share" (BR.numberToStyledHtml "%2.1f" . (100*) . mShare))
      <> C.headed "Modeled 2-party D Diff" (BR.toCell cas "M Diff" "M Diff" (BR.numberToStyledHtml "%2.1f" . (100*) . mDiff))

newStateLegMapPosts :: forall r. (K.KnitMany r, BR.CacheEffects r) => BR.CommandLine -> K.Sem r ()
newStateLegMapPosts cmdLine = do
  ccesAndCPSEM_C <-  BRE.prepCCESAndCPSEM False
  acs_C <- BRE.prepACS False
  let ccesWD_C = fmap BRE.ccesEMRows ccesAndCPSEM_C
  proposedSLDs_C <- prepCensusDistrictData False "model/NewMaps/newStateLegDemographics.bin" =<< BRC.censusTablesFor2022SLDs
  proposedCDs_C <- prepCensusDistrictData False "model/newMaps/newCDDemographicsDR.bin" =<< BRC.censusTablesForProposedCDs
  let onlyUpper = F.filterFrame ((== ET.StateUpper) . F.rgetField @ET.DistrictTypeC)
      onlyLower = F.filterFrame ((== ET.StateLower) . F.rgetField @ET.DistrictTypeC)

{-
  let postInfoNC = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished (Just BR.Unpublished))
  ncPaths <- postPaths "NC_StateLeg_Upper" cmdLine
  BR.brNewPost ncPaths postInfoNC "NC_SLDU" $ do
    overlaps <- DO.loadOverlapsFromCSV "data/districtOverlaps/NC_SLDU_CD.csv" "NC" ET.StateUpper ET.Congressional
    ncUpperDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "NC" "Passed/InLitigation" ET.StateUpper)
    cdDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis undefined -- (Redistrict.redistrictingPlanId "AZ" "Passed" ET.Congressional)
    let postSpec = NewSLDMapsPostSpec "NC" ET.StateUpper ncPaths cdDRA ncUpperDRA overlaps
    newStateLegMapAnalysis False cmdLine postSpec postInfoNC
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyUpper . onlyState "NC") proposedCDs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyUpper . onlyState "NC") proposedSLDs_C)

  ncPaths <- postPaths "NC_StateLeg_Lower" cmdLine
  BR.brNewPost ncPaths postInfoNC "NC_SLDL" $ do
    overlaps <- DO.loadOverlapsFromCSV "data/districtOverlaps/NC_SLDL_CD.csv" "NC" ET.StateLower ET.Congressional
    ncLowerDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "NC" "Passed/InLitigation" ET.StateLower)
    cdDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis undefined -- (Redistrict.redistrictingPlanId "AZ" "Passed" ET.Congressional)
    let postSpec = NewSLDMapsPostSpec "NC" ET.StateLower ncPaths cdDRA ncLowerDRA overlaps
    newStateLegMapAnalysis False cmdLine postSpec postInfoNC
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyLower . onlyState "NC") proposedCDs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyLower . onlyState "NC") proposedSLDs_C)
-}

  -- NB: AZ has only one set of districts.  Upper and lower house candidates run in the same districts!
  let postInfoAZ = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished Nothing)
  azPaths <- postPaths "AZ_StateLeg" cmdLine
  BR.brNewPost azPaths postInfoAZ "AZ_SLD" $ do
    overlaps <- DO.loadOverlapsFromCSV "data/districtOverlaps/AZ_SLD_CD.csv" "AZ" ET.StateUpper ET.Congressional
    sldDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "AZ" "Passed" ET.StateUpper)
    cdDRA <- K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "AZ" "Passed" ET.Congressional)
    let postSpec = NewSLDMapsPostSpec "AZ" ET.StateUpper azPaths sldDRA cdDRA overlaps
    newStateLegMapAnalysis False cmdLine postSpec postInfoAZ
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "AZ") proposedCDs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "AZ") proposedSLDs_C)


addRace5 :: (F.ElemOf rs DT.RaceAlone4C, F.ElemOf rs DT.HispC) => F.Record rs -> F.Record (rs V.++ '[DT.Race5C])
addRace5 r = r F.<+> (FT.recordSingleton @DT.Race5C $ DT.race5FromRaceAlone4AndHisp True (F.rgetField @DT.RaceAlone4C r) (F.rgetField @DT.HispC r))

addCount :: (F.ElemOf rs PUMS.Citizens) => F.Record rs -> F.Record (rs V.++ '[BRC.Count])
addCount r = r F.<+> (FT.recordSingleton @BRC.Count $ F.rgetField @PUMS.Citizens r)

addDistrict :: (F.ElemOf rs ET.CongressionalDistrict) => F.Record rs -> F.Record (rs V.++ '[ET.DistrictTypeC, ET.DistrictNumber])
addDistrict r = r F.<+> ((ET.Congressional F.&: F.rgetField @ET.CongressionalDistrict r F.&: V.RNil) :: F.Record [ET.DistrictTypeC, ET.DistrictNumber])

fixACS :: F.Record BRE.PUMSWithDensityEM -> F.Record PostStratR
fixACS = F.rcast . addRace5 . addDistrict . addCount

peopleWeightedLogDensity :: (F.ElemOf rs DT.PopPerSqMile, Foldable f)
                         => (F.Record rs -> Int)
                         -> f (F.Record rs)
                         -> Double
peopleWeightedLogDensity ppl rows =
  let dens = F.rgetField @DT.PopPerSqMile
      x r = if dens r >= 1 then realToFrac (ppl r) * Numeric.log (dens r) else 0
      fld = (/) <$> FL.premap x FL.sum <*> fmap realToFrac (FL.premap ppl FL.sum)
  in FL.fold fld rows

rescaleDensity :: (F.ElemOf rs DT.PopPerSqMile, Functor f)
               => Double
               -> f (F.Record rs)
               -> f (F.Record rs)
rescaleDensity s = fmap g
  where
    g = FT.fieldEndo @DT.PopPerSqMile (*s)

newCongressionalMapPosts :: forall r. (K.KnitMany r, BR.CacheEffects r) => BR.CommandLine -> K.Sem r ()
newCongressionalMapPosts cmdLine = do
  ccesAndCPSEM_C <-  BRE.prepCCESAndCPSEM False
  acs_C <- BRE.prepACS False
  let ccesWD_C = fmap BRE.ccesEMRows ccesAndCPSEM_C --prepCCESDM False (fmap BRE.districtRows ccesAndPums_C) (fmap BRE.ccesRows ccesAndPums_C)
  proposedCDs_C <- prepCensusDistrictData False "model/newMaps/newCDDemographicsDR.bin" =<< BRC.censusTablesForProposedCDs
  drExtantCDs_C <- prepCensusDistrictData False "model/newMaps/extantCDDemographicsDR.bin" =<< BRC.censusTablesForDRACDs

  let postInfoNC = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes (BR.Published $ Time.fromGregorian 2021 12 15) (Just BR.Unpublished))
  ncPaths <-  postPaths "NC_Congressional" cmdLine
  BR.brNewPost ncPaths postInfoNC "NC" $ do
    ncNMPS <- NewCDMapPostSpec "NC" ncPaths
              <$> (K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "NC" "Passed" ET.Congressional))
    newCongressionalMapAnalysis False cmdLine ncNMPS postInfoNC
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "NC") drExtantCDs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "NC") proposedCDs_C)

  let postInfoTX = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes (BR.Published $ Time.fromGregorian 2022 2 25) (Just BR.Unpublished))
  txPaths <- postPaths "TX_Congressional" cmdLine
  BR.brNewPost txPaths postInfoTX "TX" $ do
    txNMPS <- NewCDMapPostSpec "TX" txPaths
            <$> (K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "TX" "Passed" ET.Congressional))
    newCongressionalMapAnalysis False cmdLine txNMPS postInfoTX
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap fixACS . onlyState "TX") acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "TX") proposedCDs_C)

  let postInfoAZ = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished (Just BR.Unpublished))
  azPaths <- postPaths "AZ_Congressional" cmdLine
  BR.brNewPost azPaths postInfoAZ "AZ" $ do
    azNMPS <- NewCDMapPostSpec "AZ" azPaths
            <$> (K.ignoreCacheTimeM $ Redistrict.loadRedistrictingPlanAnalysis (Redistrict.redistrictingPlanId "AZ" "Passed" ET.Congressional))
    let (NewCDMapPostSpec _ _ dra) = azNMPS
    newCongressionalMapAnalysis False cmdLine azNMPS postInfoAZ
      (K.liftActionWithCacheTime ccesWD_C)
      (K.liftActionWithCacheTime ccesAndCPSEM_C)
      (K.liftActionWithCacheTime acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap fixACS . onlyState "AZ") acs_C)
      (K.liftActionWithCacheTime $ fmap (fmap F.rcast . onlyState "AZ") proposedCDs_C)


districtColonnade cas =
  let state = F.rgetField @DT.StateAbbreviation
      dNum = F.rgetField @ET.DistrictNumber
      share5 = MT.ciLower . F.rgetField @BRE.ModeledShare
      share50 = MT.ciMid . F.rgetField @BRE.ModeledShare
      share95 = MT.ciUpper . F.rgetField @BRE.ModeledShare
  in C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
     <> C.headed "District" (BR.toCell cas "District" "District" (BR.numberToStyledHtml "%d" . dNum))
--     <> C.headed "2019 Result" (BR.toCell cas "2019" "2019" (BR.numberToStyledHtml "%2.2f" . (100*) . F.rgetField @BR.DShare))
     <> C.headed "5%" (BR.toCell cas "5%" "5%" (BR.numberToStyledHtml "%2.2f" . (100*) . share5))
     <> C.headed "50%" (BR.toCell cas "50%" "50%" (BR.numberToStyledHtml "%2.2f" . (100*) . share50))
     <> C.headed "95%" (BR.toCell cas "95%" "95%" (BR.numberToStyledHtml "%2.2f" . (100*) . share95))

modelCompColonnade states cas =
  C.headed "Model" (BR.toCell cas "Model" "Model" (BR.textToStyledHtml . fst))
  <> mconcat (fmap (\s -> C.headed (BR.textToCell s) (BR.toCell cas s s (BR.maybeNumberToStyledHtml "%2.2f" . M.lookup s . snd))) states)



type ModelPredictorR = [DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC, DT.PopPerSqMile]
type PostStratR = [BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber] V.++ ModelPredictorR V.++ '[BRC.Count]
type ElexDShare = "ElexDShare" F.:-> Double
type TwoPartyDShare = "2-Party DShare" F.:-> Double

twoPartyDShare r =
  let ds = F.rgetField @ET.DemShare r
      rs = F.rgetField @ET.RepShare r
  in FT.recordSingleton @TwoPartyDShare $ ds/(ds + rs)

addTwoPartyDShare r = r F.<+> twoPartyDShare r

--data ExtantDistricts = PUMSDistricts | DRADistricts

data NewSLDMapsPostSpec = NewSLDMapsPostSpec { stateAbbr :: Text
                                             , districtType :: ET.DistrictType
                                             , paths :: BR.PostPaths BR.Abs
                                             , sldDRAnalysis :: F.Frame Redistrict.DRAnalysis
                                             , cdDRAnalysis :: F.Frame Redistrict.DRAnalysis
                                             , overlaps :: DO.DistrictOverlaps Int
                                             }

newStateLegMapAnalysis :: forall r.(K.KnitMany r, K.KnitOne r, BR.CacheEffects r)
                       => Bool
                       -> BR.CommandLine
                       -> NewSLDMapsPostSpec
                       -> BR.PostInfo
                       -> K.ActionWithCacheTime r (F.FrameRec BRE.CCESWithDensityEM)
                       -> K.ActionWithCacheTime r BRE.CCESAndCPSEM
                       -> K.ActionWithCacheTime r (F.FrameRec BRE.PUMSWithDensityEM) -- ACS data
                       -> K.ActionWithCacheTime r (F.FrameRec PostStratR) -- (proposed) congressional districts
                       -> K.ActionWithCacheTime r (F.FrameRec PostStratR) -- proposed SLDs
                       -> K.Sem r ()
newStateLegMapAnalysis clearCaches cmdLine postSpec postInfo ccesWD_C ccesAndCPSEM_C acs_C cdDemo_C sldDemo_C = K.wrapPrefix "newStateLegMapAnalysis" $ do
  K.logLE K.Info $ "Rebuilding state-leg map analysis for " <> stateAbbr postSpec <> "( " <> show (districtType postSpec) <> ")"
  BR.brAddPostMarkDownFromFile (paths postSpec) "_intro"
  let ccesAndCPS2020_C = fmap (BRE.ccesAndCPSForYears [2020]) ccesAndCPSEM_C
      acs2020_C = fmap (BRE.acsForYears [2020]) acs_C
--      dmModel = BRE.Model ET.TwoPartyShare (one ET.President) BRE.LogDensity

      stanParams = SC.StanMCParameters 4 4 (Just 1000) (Just 1000) (Just 0.8) (Just 10) Nothing
      mapGroup :: SB.GroupTypeTag (F.Record CDLocWStAbbrR) = SB.GroupTypeTag "CD"
      postStratInfo dt = (mapGroup
                         , "DM" <> "_" <> stateAbbr postSpec <> "_" <> show dt
                         , SB.addGroupToSet BRE.stateGroup SB.emptyGroupSet
                         )
      modelDM :: ET.DistrictType
              -> K.ActionWithCacheTime r (F.FrameRec PostStratR)
              -> K.Sem r (BRE.ModelCrossTabs, F.FrameRec (BRE.ModelResultsR CDLocWStAbbrR))
      modelDM dt x = do
        let gqDeps = (,) <$> acs2020_C <*> x
        K.ignoreCacheTimeM $ BRE.electionModelDM False cmdLine (Just stanParams) modelDir modelVariant 2020 (postStratInfo dt) ccesAndCPS2020_C gqDeps
  (_, modeledCDs) <- modelDM ET.Congressional (fmap F.rcast <$> cdDemo_C)
  (_, modeledSLDs) <- modelDM (districtType postSpec) (fmap F.rcast <$> sldDemo_C)
  sldDemo <- K.ignoreCacheTime sldDemo_C
{-  let (modelDRA, modelDRAMissing)
        = FJ.leftJoinWithMissing @[BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
        modeled
        (fmap addTwoPartyDShare dra)
  when (not $ null modelDRAMissing) $ K.knitError $ "newStateLegAnalysis: missing keys in demographics/model join. " <> show modelDRAMissing
-}
  let (modelDRA, modelDRAMissing)
        = FJ.leftJoinWithMissing @[BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
        modeledSLDs
        (fmap addTwoPartyDShare $ sldDRAnalysis postSpec)
  when (not $ null modelDRAMissing) $ K.knitError $ "newStateLegAnalysis: missing keys in model/DRA join. " <> show modelDRAMissing
  let modMid = round . (100*). MT.ciMid . F.rgetField @BRE.ModeledShare
      dra = round . (100*) . F.rgetField @TwoPartyDShare
      inRange r = (modMid r >= 40 && modMid r <= 60) || (dra r >= 40 && dra r <= 60)
      modelAndDRAInRange = {- F.filterFrame inRange -} modelDRA
  let dNum = F.rgetField @ET.DistrictNumber
      modMid r = round @_ @Int . (100*) $ MT.ciMid $ F.rgetField @BRE.ModeledShare r
      dra r =  round @_ @Int . (100*) $ F.rgetField @TwoPartyDShare r
      cdModelMap = FL.fold (FL.premap (\r -> (dNum r, modMid r)) FL.map) modeledCDs
      cdDRAMap = FL.fold (FL.premap (\r -> (dNum r, dra r)) FL.map) $ fmap addTwoPartyDShare $ cdDRAnalysis postSpec
      modelCompetitive n = brCompetitive || draCompetitive
        where draCompetitive = fromMaybe False $ fmap (between draShareRange) $ M.lookup n cdDRAMap
              brCompetitive = fromMaybe False $ fmap (between brShareRange) $ M.lookup n cdModelMap
      sortedModelAndDRA = reverse $ sortOn (MT.ciMid . F.rgetField @BRE.ModeledShare) $ FL.fold FL.list modelAndDRAInRange
      tableCAS ::  (F.ElemOf rs BRE.ModeledShare, F.ElemOf rs TwoPartyDShare, F.ElemOf rs ET.DistrictNumber) => BR.CellStyle (F.Record rs) String
      tableCAS =  modelVsHistoricalTableCellStyle <> "border: 3px solid green" `BR.cellStyleIf` \r h -> f r && h == "CD Overlaps"
        where
          os r = fmap fst $ DO.overlapsOverThresholdForRow 0.25 (overlaps postSpec) (dNum r)
          f r = Monoid.getAny $ mconcat $ fmap (Monoid.Any . modelCompetitive) (os r)
  BR.brAddRawHtmlTable
    ("Dem Vote Share, " <> stateAbbr postSpec <> " State-Leg (" <> show (districtType postSpec) <> ") 2022: Demographic Model vs. Historical Model (DR)")
    (BHA.class_ "brTable")
    (dmColonnadeOverlap 0.25 (overlaps postSpec) tableCAS)
    sortedModelAndDRA
  BR.brAddPostMarkDownFromFile (paths postSpec) "_afterModelDRATable"
  let sldByModelShare = modelShareSort modeledSLDs --proposedPlusStateAndStateRace_RaceDensityNC
  _ <- K.addHvega Nothing Nothing
       $ BRV.demoCompare
       ("Race", show . F.rgetField @DT.Race5C, raceSort)
       ("Education", show . F.rgetField @DT.CollegeGradC, eduSort)
       (F.rgetField @BRC.Count)
       ("District", \r -> F.rgetField @DT.StateAbbreviation r <> "-" <> textDist r, Just sldByModelShare)
       (Just ("log(Density)", (\x -> x) . Numeric.log . F.rgetField @DT.PopPerSqMile))
       (stateAbbr postSpec <> " New: By Race and Education")
       (FV.ViewConfig 600 600 5)
       sldDemo

  let (modelDRADemo, demoMissing) = FJ.leftJoinWithMissing @[BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
                                    modelDRA
                                    sldDemo
  when (not $ null demoMissing) $ K.knitError $ "newStateLegAnalysis: missing keys in modelDRA/demo join. " <> show demoMissing
  _ <- K.addHvega Nothing Nothing
      $ BRV.demoCompareXYCS
      "District"
     "% non-white"
      "% college grad"
      "Modeled D-Edge"
      "log density"
      (stateAbbr postSpec <> " demographic scatter")
      (FV.ViewConfig 600 600 5)
      (FL.fold xyFold' modelDRADemo)
  pure ()

dmColonnadeOverlap x ols cas =
  let state = F.rgetField @DT.StateAbbreviation
      dNum = F.rgetField @ET.DistrictNumber
      dave = round @_ @Int . (100*) . F.rgetField @TwoPartyDShare
      share50 = round @_ @Int . (100 *) . MT.ciMid . F.rgetField @BRE.ModeledShare
  in C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
     <> C.headed "District" (BR.toCell cas "District" "District" (BR.numberToStyledHtml "%d" . dNum))
     <> C.headed "Demographic Model (Blue Ripple)" (BR.toCell cas "Demographic" "Demographic" (BR.numberToStyledHtml "%d" . share50))
     <> C.headed "Historical Model (Dave's Redistricting)" (BR.toCell cas "Historical" "Historical" (BR.numberToStyledHtml "%d" . dave))
     <> C.headed "BR Stance" (BR.toCell cas "BR Stance" "BR Stance" (BR.textToStyledHtml . (\r -> brDistrictFramework brShareRange draShareRange (share50 r) (dave r))))
     <> C.headed "CD Overlaps" (BR.toCell cas "CD Overlaps" "CD Overlaps" (BR.textToStyledHtml . T.intercalate "," . fmap (show . fst) . DO.overlapsOverThresholdForRow x ols . dNum))

data NewCDMapPostSpec = NewCDMapPostSpec Text (BR.PostPaths BR.Abs) (F.Frame Redistrict.DRAnalysis)

newCongressionalMapAnalysis :: forall r.(K.KnitMany r, K.KnitOne r, BR.CacheEffects r)
                            => Bool
                            -> BR.CommandLine
                            -> NewCDMapPostSpec
                            -> BR.PostInfo
                            -> K.ActionWithCacheTime r (F.FrameRec BRE.CCESWithDensityEM)
                            -> K.ActionWithCacheTime r BRE.CCESAndCPSEM
                            -> K.ActionWithCacheTime r (F.FrameRec BRE.PUMSWithDensityEM) -- ACS data
                            -> K.ActionWithCacheTime r (F.FrameRec PostStratR) -- extant districts
                            -> K.ActionWithCacheTime r (F.FrameRec PostStratR) -- new districts
                            -> K.Sem r ()
newCongressionalMapAnalysis clearCaches cmdLine postSpec postInfo ccesWD_C ccesAndCPSEM_C acs_C extantDemo_C proposedDemo_C = K.wrapPrefix "newCongressionalMapsAnalysis" $ do
  let (NewCDMapPostSpec stateAbbr postPaths drAnalysis) = postSpec
  K.logLE K.Info $ "Re-building NewMaps " <> stateAbbr <> " post"
  let ccesAndCPS2018_C = fmap (BRE.ccesAndCPSForYears [2018]) ccesAndCPSEM_C
      ccesAndCPS2020_C = fmap (BRE.ccesAndCPSForYears [2020]) ccesAndCPSEM_C
      acs2020_C = fmap (BRE.acsForYears [2020]) acs_C
  extant <- K.ignoreCacheTime extantDemo_C
  proposed <- K.ignoreCacheTime proposedDemo_C
  acsForState <- fmap (F.filterFrame ((== stateAbbr) . F.rgetField @BR.StateAbbreviation)) $ K.ignoreCacheTime acs2020_C
  let extantPWLD = peopleWeightedLogDensity (F.rgetField @BRC.Count) extant
      proposedPWLD = peopleWeightedLogDensity (F.rgetField @BRC.Count) proposed
      acs2020PWLD = peopleWeightedLogDensity (F.rgetField @PUMS.Citizens) acsForState
      rescaleExtant = rescaleDensity $ Numeric.exp (acs2020PWLD - extantPWLD)
      rescaleProposed = rescaleDensity $ Numeric.exp (acs2020PWLD - proposedPWLD)
  K.logLE K.Info $ "People-weighted log-density: acs=" <> show acs2020PWLD <> "; extant=" <> show extantPWLD <> "; proposed=" <> show proposedPWLD
  --      ccesVoteSource = BRE.CCESComposite
  let addDistrict r = r F.<+> ((ET.Congressional F.&: F.rgetField @ET.CongressionalDistrict r F.&: V.RNil) :: F.Record [ET.DistrictTypeC, ET.DistrictNumber])
      addElexDShare r = let dv = F.rgetField @BRE.DVotes r
                            rv = F.rgetField @BRE.RVotes r
                        in r F.<+> (FT.recordSingleton @ElexDShare $ if (dv + rv) == 0 then 0 else (realToFrac dv/realToFrac (dv + rv)))
--      modelDir =  "br-2021-NewMaps/stanAH"
      mapGroup :: SB.GroupTypeTag (F.Record CDLocWStAbbrR) = SB.GroupTypeTag "CD"
      psInfoDM name = (mapGroup
                      , "DM" <> "_" <> name
                      , SB.addGroupToSet BRE.stateGroup (SB.emptyGroupSet)
                      )
      stanParams = SC.StanMCParameters 4 4 (Just 1000) (Just 1000) (Just 0.8) (Just 10) Nothing
--      model = BRE.Model ET.TwoPartyShare (one ET.President) BRE.LogDensity
      modelDM :: BRE.Model -> Text -> K.ActionWithCacheTime r (F.FrameRec PostStratR)
              -> K.Sem r (BRE.ModelCrossTabs, F.FrameRec (BRE.ModelResultsR CDLocWStAbbrR))
      modelDM model name x = do
        let gqDeps = (,) <$> acs2020_C <*> x
        K.ignoreCacheTimeM $ BRE.electionModelDM False cmdLine (Just stanParams) modelDir modelVariant 2020 (psInfoDM name) ccesAndCPS2020_C gqDeps

  (_, proposedBaseHV) <- modelDM modelVariant (stateAbbr <> "_Proposed") (rescaleProposed . fmap F.rcast <$> proposedDemo_C)
  (_, extantBaseHV) <- modelDM modelVariant (stateAbbr <> "_Proposed") (rescaleExtant . fmap F.rcast <$> extantDemo_C)

--  (ccesAndCPS_CrossTabs, extantBaseHV) <- modelDM modelVariant BRE.CCESAndCPS (stateAbbr <> "_Extant") $ (fmap F.rcast <$> extantDemo_C)
--  (_, proposedBaseHV) <- modelDM modelVariant BRE.CCESAndCPS (stateAbbr <> "_Proposed") $ (fmap F.rcast <$> proposedDemo_C)
--  BR.logFrame proposedBaseHV
--  K.ignoreCacheTime proposedDemo_C >>= BR.logFrame

  let extantForPost = extantBaseHV
      proposedForPost = proposedBaseHV
  elections_C <- BR.houseElectionsWithIncumbency
  elections <- fmap (onlyState stateAbbr) $ K.ignoreCacheTime elections_C
  flattenedElections <- fmap (addDistrict . addElexDShare) . F.filterFrame ((==2020) . F.rgetField @BR.Year)
                        <$> (K.knitEither $ FL.foldM (BRE.electionF @[BR.Year, BR.StateAbbreviation, BR.CongressionalDistrict]) $ F.rcast <$> elections)
  let
      oldDistrictsNoteName = BR.Used "Old_Districts"
  extantDemo <- K.ignoreCacheTime extantDemo_C
  mOldDistrictsUrl <- BR.brNewNote postPaths postInfo oldDistrictsNoteName (stateAbbr <> ": Old Districts") $ do
    BR.brAddNoteMarkDownFromFile postPaths oldDistrictsNoteName "_intro"
    let extantByModelShare = modelShareSort extantBaseHV --extantPlusStateAndStateRace_RaceDensityNC
    _ <- K.addHvega Nothing Nothing
         $ BRV.demoCompare
         ("Race", show . F.rgetField @DT.Race5C, raceSort)
         ("Education", show . F.rgetField @DT.CollegeGradC, eduSort)
         (F.rgetField @BRC.Count)
         ("District", \r -> F.rgetField @DT.StateAbbreviation r <> "-" <> textDist r, Just extantByModelShare)
         (Just ("log(Density)", Numeric.log . F.rgetField @DT.PopPerSqMile))
         (stateAbbr <> " Old: By Race and Education")
         (FV.ViewConfig 600 600 5)
         extantDemo
    BR.brAddNoteMarkDownFromFile postPaths oldDistrictsNoteName "_afterDemographicsBar"
    let (demoElexModelExtant, missing1E, missing2E)
          = FJ.leftJoin3WithMissing @[DT.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
            (onlyState stateAbbr extantDemo)
            flattenedElections
            extantBaseHV
--            extantPlusStateAndStateRace_RaceDensityNC
    when (not $ null missing1E) $ do
      BR.logFrame extantDemo
      K.knitError $ "Missing keys in join of extant demographics and election results:" <> show missing1E
    when (not $ null missing2E) $ K.knitError $ "Missing keys in join of extant demographics and model:" <> show missing2E
    _ <- K.addHvega Nothing Nothing
      $ BRV.demoCompareXYCS
      "District"
     "% non-white"
      "% college grad"
      "Modeled D-Edge"
      "log density"
      (stateAbbr <> " demographic scatter")
      (FV.ViewConfig 600 600 5)
      (FL.fold xyFold' demoElexModelExtant)
    BR.brAddNoteMarkDownFromFile postPaths oldDistrictsNoteName "_afterDemographicsScatter"

    let (oldMapsCompare, missing)
          = FJ.leftJoinWithMissing @[BR.Year, DT.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
            flattenedElections
            extantForPost
    when (not $ null missing) $ K.knitError $ "Missing keys in join of election results and model:" <> show missing
    _ <- K.addHvega Nothing Nothing
         $ modelAndElectionScatter
         True
         (stateAbbr <> " 2020: Election vs Demographic Model")
         (FV.ViewConfig 600 600 5)
         (fmap F.rcast oldMapsCompare)
    BR.brAddNoteMarkDownFromFile postPaths oldDistrictsNoteName "_afterModelElection"
    BR.brAddRawHtmlTable
      ("2020 Dem Vote Share, " <> stateAbbr <> ": Demographic Model vs. Election Results")
      (BHA.class_ "brTable")
      (extantModeledColonnade mempty)
      oldMapsCompare
  oldDistrictsNoteUrl <- K.knitMaybe "extant districts Note Url is Nothing" $ mOldDistrictsUrl
  let oldDistrictsNoteRef = "[oldDistricts]:" <> oldDistrictsNoteUrl
  BR.brAddPostMarkDownFromFile postPaths "_intro"
  let (modelAndDR, missing)
        = FJ.leftJoinWithMissing @[DT.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
          proposedForPost
--          proposedPlusStateAndStateRace_RaceDensityNC
          (fmap addTwoPartyDShare drAnalysis)
  _ <- K.addHvega Nothing Nothing
       $ modelAndDaveScatterChart
       True
       (stateAbbr <> " 2022: Historical vs. Demographic models")
       (FV.ViewConfig 600 600 5)
       (fmap F.rcast modelAndDR)
  BR.brAddPostMarkDownFromFile postPaths "_afterDaveModel"
  let sortedModelAndDRA = reverse $ sortOn (MT.ciMid . F.rgetField @BRE.ModeledShare) $ FL.fold FL.list modelAndDR
  BR.brAddRawHtmlTable
    ("Calculated Dem Vote Share, " <> stateAbbr <> " 2022: Demographic Model vs. Historical Model (DR)")
    (BHA.class_ "brTable")
    (daveModelColonnade modelVsHistoricalTableCellStyle)
    sortedModelAndDRA
  BR.brAddPostMarkDownFromFile postPaths "_daveModelTable"
--  BR.brAddPostMarkDownFromFile postPaths "_beforeNewDemographics"
  let proposedByModelShare = modelShareSort proposedBaseHV --proposedPlusStateAndStateRace_RaceDensityNC
  proposedDemo <- K.ignoreCacheTime proposedDemo_C
  _ <- K.addHvega Nothing Nothing
       $ BRV.demoCompare
       ("Race", show . F.rgetField @DT.Race5C, raceSort)
       ("Education", show . F.rgetField @DT.CollegeGradC, eduSort)
       (F.rgetField @BRC.Count)
       ("District", \r -> F.rgetField @DT.StateAbbreviation r <> "-" <> textDist r, Just proposedByModelShare)
       (Just ("log(Density)", (\x -> x) . Numeric.log . F.rgetField @DT.PopPerSqMile))
       (stateAbbr <> " New: By Race and Education")
       (FV.ViewConfig 600 600 5)
       proposedDemo
  let (demoModelAndDR, missing1P, missing2P)
        = FJ.leftJoin3WithMissing @[DT.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
          (onlyState stateAbbr proposedDemo)
          proposedForPost
--          proposedPlusStateAndStateRace_RaceDensityNC
          (fmap addTwoPartyDShare drAnalysis)
  when (not $ null missing1P) $ K.knitError $ "Missing keys when joining demographics results and model: " <> show missing1P
  when (not $ null missing2P) $ K.knitError $ "Missing keys when joining demographics results and Dave's redistricting analysis: " <> show missing2P
--  BR.brAddPostMarkDownFromFile postPaths "_afterNewDemographicsBar"
  _ <- K.addHvega Nothing Nothing
    $ BRV.demoCompareXYCS
    "District"
    "% non-white"
    "% college grad"
    "Modeled D-Edge"
    "log density"
    (stateAbbr <> " demographic scatter")
    (FV.ViewConfig 600 600 5)
    (FL.fold xyFold' demoModelAndDR)
  BR.brAddPostMarkDownFromFileWith postPaths "_afterNewDemographics" (Just oldDistrictsNoteRef)

  return ()

safeLog x = if x < 1e-12 then 0 else Numeric.log x
xyFold' = FMR.mapReduceFold
          FMR.noUnpack
          (FMR.assignKeysAndData @[DT.StateAbbreviation, ET.DistrictNumber, ET.DistrictTypeC] @[BRC.Count, DT.Race5C, DT.CollegeGradC, DT.PopPerSqMile, BRE.ModeledShare])
          (FMR.foldAndLabel foldData (\k (x :: Double, y :: Double, c, s) -> (distLabel k, x, y, c, s)))
        where
          allF = FL.premap (F.rgetField @BRC.Count) FL.sum
          wnhF = FL.prefilter ((/= DT.R5_WhiteNonHispanic) . F.rgetField @DT.Race5C) allF
          gradsF = FL.prefilter ((== DT.Grad) . F.rgetField @DT.CollegeGradC) allF
          densityF = fmap (fromMaybe 0) $ FL.premap (safeLog . F.rgetField @DT.PopPerSqMile) FL.last
          modelF = fmap (fromMaybe 0) $ FL.premap (MT.ciMid . F.rgetField @BRE.ModeledShare) FL.last
          foldData = (\a wnh grads m d -> (100 * realToFrac wnh/ realToFrac a, 100 * realToFrac grads/realToFrac a, 100*(m - 0.5), d))
                     <$> allF <*> wnhF <*> gradsF <*> modelF <*> densityF

raceSort = Just $ show <$> [DT.R5_WhiteNonHispanic, DT.R5_Black, DT.R5_Hispanic, DT.R5_Asian, DT.R5_Other]

eduSort = Just $ show <$> [DT.NonGrad, DT.Grad]

textDist :: F.ElemOf rs ET.DistrictNumber => F.Record rs -> Text
textDist r = let x = F.rgetField @ET.DistrictNumber r in if x < 10 then "0" <> show x else show x

distLabel :: (F.ElemOf rs ET.DistrictNumber, F.ElemOf rs BR.StateAbbreviation) => F.Record rs -> Text
distLabel r = F.rgetField @DT.StateAbbreviation r <> "-" <> textDist r

modelShareSort :: (Foldable f
                  , F.ElemOf rs BRE.ModeledShare
                  , F.ElemOf rs ET.DistrictNumber
                  , F.ElemOf rs BR.StateAbbreviation
                  ) => f (F.Record rs) -> [Text]
modelShareSort = reverse . fmap fst . sortOn snd
                 . fmap (\r -> (distLabel r, MT.ciMid $ F.rgetField @BRE.ModeledShare r))
                 . FL.fold FL.list

brShareRange :: (Int, Int)
brShareRange = (45, 55)
draShareRange :: (Int, Int)
draShareRange = (47, 53)

between :: (Int, Int) -> Int -> Bool
between (l, h) x = x >= l && x <= h


modelVsHistoricalTableCellStyle :: (F.ElemOf rs BRE.ModeledShare
                                   , F.ElemOf rs TwoPartyDShare)
                                => BR.CellStyle (F.Record rs) String
modelVsHistoricalTableCellStyle = mconcat [longShotCS, leanRCS, leanDCS, safeDCS, longShotDRACS, leanRDRACS, leanDDRACS, safeDDRACS]
  where
    safeR (l, _) x = x <= l
    leanR (l, _) x = x < 50 && x  >= l
    leanD (_, u) x = x >= 50 && x <= u
    safeD (_, u) x = x > u
    modMid = round . (100*). MT.ciMid . F.rgetField @BRE.ModeledShare
    bordered c = "border: 3px solid " <> c
    longShotCS  = bordered "red" `BR.cellStyleIf` \r h -> safeR brShareRange (modMid r) && h == "Demographic"
    leanRCS =  bordered "pink" `BR.cellStyleIf` \r h -> leanR brShareRange (modMid r) && h `elem` ["Demographic"]
    leanDCS = bordered "skyblue" `BR.cellStyleIf` \r h -> leanD brShareRange (modMid r) && h `elem` ["Demographic"]
    safeDCS = bordered "blue"  `BR.cellStyleIf` \r h -> safeD brShareRange (modMid r) && h == "Demographic"
    dra = round . (100*) . F.rgetField @TwoPartyDShare
    longShotDRACS = bordered "red" `BR.cellStyleIf` \r h -> safeR draShareRange (dra r) && h == "Historical"
    leanRDRACS = bordered "pink" `BR.cellStyleIf` \r h -> leanR draShareRange (dra r) && h == "Historical"
    leanDDRACS = bordered "skyblue" `BR.cellStyleIf` \r h -> leanD draShareRange (dra r)&& h == "Historical"
    safeDDRACS = bordered "blue" `BR.cellStyleIf` \r h -> safeD draShareRange (dra r) && h == "Historical"

data DistType = SafeR | LeanR | LeanD | SafeD deriving (Eq, Ord, Show)
distType :: Int -> Int -> Int -> DistType
distType safeRUpper safeDLower x
  | x < safeRUpper = SafeR
  | x >= safeRUpper && x < 50 = LeanR
  | x >= 50 && x <= safeDLower = LeanD
  | otherwise = SafeD

brDistrictFramework :: (Int, Int) -> (Int, Int) -> Int -> Int -> Text
brDistrictFramework brRange draRange brModel dra =
  case (uncurry distType brRange brModel, uncurry distType draRange dra) of
    (SafeD, SafeR) -> "Latent Flip/Win Opportunity"
    (SafeD, LeanD) -> "Flippable/Winnable"
    (SafeD, LeanR) -> "Flippable/Winnable"
    (SafeD, SafeD) -> "Safe D"
    (LeanD, SafeR) -> "Latent Flip Opportunity"
    (LeanR, SafeR) -> "Possible Long-Term Win/Flip"
    (LeanD, LeanR) -> "Toss-Up"
    (LeanR, LeanR) -> "Toss-Up"
    (LeanD, LeanD) -> "Toss-Up"
    (LeanR, LeanD) -> "Toss-Up"
    (LeanD, SafeD) -> "Possible Long-Term Vulnerability"
    (LeanR, SafeD) -> "Latent Vulnerability"
    (SafeR, SafeR) -> "Safe R"
    (SafeR, LeanR) -> "Highly Vulnerable"
    (SafeR, LeanD) -> "Highly Vulnerable"
    (SafeR, SafeD) -> "Latent Vulnerability"


daveModelColonnade cas =
  let state = F.rgetField @DT.StateAbbreviation
      dNum = F.rgetField @ET.DistrictNumber
      dave = round @_ @Int . (100*) . F.rgetField @TwoPartyDShare
      share50 = round @_ @Int . (100 *) . MT.ciMid . F.rgetField @BRE.ModeledShare
  in C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
     <> C.headed "District" (BR.toCell cas "District" "District" (BR.numberToStyledHtml "%d" . dNum))
     <> C.headed "Demographic Model (Blue Ripple)" (BR.toCell cas "Demographic" "Demographic" (BR.numberToStyledHtml "%d" . share50))
     <> C.headed "Historical Model (Dave's Redistricting)" (BR.toCell cas "Historical" "Historical" (BR.numberToStyledHtml "%d" . dave))
     <> C.headed "BR Stance" (BR.toCell cas "BR Stance" "BR Stance" (BR.textToStyledHtml . (\r -> brDistrictFramework brShareRange draShareRange (share50 r) (dave r))))


extantModeledColonnade cas =
  let state = F.rgetField @DT.StateAbbreviation
      dNum = F.rgetField @ET.DistrictNumber
      share50 = round @_ @Int . (100*) . MT.ciMid . F.rgetField @BRE.ModeledShare
      elexDVotes = F.rgetField @BRE.DVotes
      elexRVotes = F.rgetField @BRE.RVotes
      elexShare r = realToFrac @_ @Double (elexDVotes r)/realToFrac (elexDVotes r + elexRVotes r)
  in C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
     <> C.headed "District" (BR.toCell cas "District" "District" (BR.numberToStyledHtml "%d" . dNum))
     <> C.headed "Demographic Model (Blue Ripple)" (BR.toCell cas "Demographic" "Demographic" (BR.numberToStyledHtml "%d" . share50))
     <> C.headed "2020 Election" (BR.toCell cas "Election" "Election" (BR.numberToStyledHtml "%2.0f" . (100*) . elexShare))
--


{-
race5FromCPS :: F.Record BRE.CPSVByCDR -> DT.Race5
race5FromCPS r =
  let race4A = F.rgetField @DT.RaceAlone4C r
      hisp = F.rgetField @DT.HispC r
  in DT.race5FromRaceAlone4AndHisp True race4A hisp
-}

densityHistogram :: Foldable f => Text -> FV.ViewConfig -> (Double -> Double) -> Double -> f (F.Record '[DT.PopPerSqMile]) -> GV.VegaLite
densityHistogram title vc g stepSize rows =
  let toVLDataRec = FVD.asVLData (GV.Number . g) "f(Density)" V.:& V.RNil
      vlData = FVD.recordsToData toVLDataRec rows
      encDensity = GV.position GV.X [GV.PName "f(Density)", GV.PmType GV.Quantitative, GV.PBin [GV.Step stepSize]]
      encCount = GV.position GV.Y [GV.PAggregate GV.Count, GV.PmType GV.Quantitative]
      enc = GV.encoding . encDensity . encCount
  in FV.configuredVegaLite vc [FV.title title, enc [], GV.mark GV.Bar [], vlData]



modelAndElectionScatter :: Bool
                         -> Text
                         -> FV.ViewConfig
                         -> F.FrameRec [DT.StateAbbreviation, ET.DistrictNumber, ElexDShare, BRE.ModelDesc, BRE.ModeledShare]
                         -> GV.VegaLite
modelAndElectionScatter single title vc rows =
  let toVLDataRec = FVD.asVLData GV.Str "State"
                    V.:& FVD.asVLData (GV.Number . realToFrac) "District"
                    V.:& FVD.asVLData (GV.Number . (*100)) "Election Result"
                    V.:& FVD.asVLData (GV.Str . show) "Demographic Model Type"
                    V.:& FVD.asVLData' [("Demographic Model", GV.Number . (*100) . MT.ciMid)
                                       ,("Demographic Model (95% CI)", GV.Number . (*100) . MT.ciUpper)
                                       ,("Demographic Model (5% CI)", GV.Number . (*100) . MT.ciLower)
                                       ]
                    V.:& V.RNil
      vlData = FVD.recordsToData toVLDataRec rows
      makeDistrictName = GV.transform . GV.calculateAs "datum.State + '-' + datum.District" "District Name"
--      xScale = GV.PScale [GV.SDomain (GV.DNumbers [30, 80])]
--      yScale = GV.PScale [GV.SDomain (GV.DNumbers [30, 80])]
      xScale = GV.PScale [GV.SZero False]
      yScale = GV.PScale [GV.SZero False]
      facetModel = [GV.FName "Demographic Model Type", GV.FmType GV.Nominal]
      encModelMid = GV.position GV.Y ([GV.PName "Demographic Model"
                                     , GV.PmType GV.Quantitative
                                     , GV.PScale [GV.SZero False]
                                     , yScale
                                     , GV.PAxis [GV.AxTitle "Demographic Model"]
                                     ]

                                     )
      encModelLo = GV.position GV.Y [GV.PName "Demographic Model (5% CI)"
                                    , GV.PmType GV.Quantitative
                                    , GV.PAxis [GV.AxTitle "Demographic Model"]
                                    , yScale
                                  ]
      encModelHi = GV.position GV.Y2 [GV.PName "Demographic Model (95% CI)"
                                  , GV.PmType GV.Quantitative
                                  , yScale
                                  ]
      encElection = GV.position GV.X [GV.PName "Election Result"
                                     , GV.PmType GV.Quantitative
                                     , GV.PAxis [GV.AxTitle "Election D-Share"]
                                     , xScale
                                  ]
      enc45 =  GV.position GV.X [GV.PName "Demographic Model"
                                  , GV.PmType GV.Quantitative
                                  , GV.PAxis [GV.AxTitle ""]
                                  , GV.PAxis [GV.AxTitle "Election D-Share"]
                                  , xScale
                                  ]
      encDistrictName = GV.text [GV.TName "District Name", GV.TmType GV.Nominal]
      encTooltips = GV.tooltips [[GV.TName "District", GV.TmType GV.Nominal]
                                , [GV.TName "Election Result", GV.TmType GV.Quantitative]
                                , [GV.TName "Demographic Model", GV.TmType GV.Quantitative]
                                ]
      encCITooltips = GV.tooltips [[GV.TName "District", GV.TmType GV.Nominal]
                                  , [GV.TName "Election Result", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model (5% CI)", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model (95% CI)", GV.TmType GV.Quantitative]
                                  ]

      facets = GV.facet [GV.RowBy facetModel]
      selection = (GV.selection . GV.select "view" GV.Interval [GV.Encodings [GV.ChX, GV.ChY], GV.BindScales, GV.Clear "click[event.shiftKey]"]) []
      ptEnc = GV.encoding . encModelMid . encElection . encTooltips -- . encSurvey
      ptSpec = GV.asSpec [selection, ptEnc [], GV.mark GV.Circle [], selection]
      lineEnc = GV.encoding . encModelMid . enc45
      labelEnc = ptEnc . encDistrictName
      ciEnc = GV.encoding . encModelLo . encModelHi . encElection . encCITooltips
      ciSpec = GV.asSpec [ciEnc [], GV.mark GV.ErrorBar [GV.MTicks [GV.MColor "black"]]]
      lineSpec = GV.asSpec [lineEnc [], GV.mark GV.Line [GV.MTooltip GV.TTNone]]
      labelSpec = GV.asSpec [labelEnc [], GV.mark GV.Text [GV.MdX 20], makeDistrictName []]
      finalSpec = if single
                  then [FV.title title, GV.layer [lineSpec, labelSpec, ciSpec, ptSpec], vlData]
                  else [FV.title title, facets, GV.specification (GV.asSpec [GV.layer [lineSpec, labelSpec, ciSpec, ptSpec]]), vlData]
  in FV.configuredVegaLite vc finalSpec --



modelAndDaveScatterChart :: Bool
                         -> Text
                         -> FV.ViewConfig
                         -> F.FrameRec ([BR.StateAbbreviation, ET.DistrictNumber, BRE.ModelDesc, BRE.ModeledShare, TwoPartyDShare])
                         -> GV.VegaLite
modelAndDaveScatterChart single title vc rows =
  let toVLDataRec = FVD.asVLData GV.Str "State"
                    V.:& FVD.asVLData (GV.Number . realToFrac) "District"
                    V.:& FVD.asVLData GV.Str "Demographic Model Type"
                    V.:& FVD.asVLData' [("Demographic Model", GV.Number . (*100) . MT.ciMid)
                                       ,("Demographic Model (95% CI)", GV.Number . (*100) . MT.ciUpper)
                                       ,("Demographic Model (5% CI)", GV.Number . (*100) . MT.ciLower)
                                       ]
                    V.:& FVD.asVLData (GV.Number . (*100)) "Historical Model"
                    V.:& V.RNil
      vlData = FVD.recordsToData toVLDataRec rows
      makeDistrictName = GV.transform . GV.calculateAs "datum.State + '-' + datum.District" "District Name"
--      xScale = GV.PScale [GV.SDomain (GV.DNumbers [35, 75])]
--      yScale = GV.PScale [GV.SDomain (GV.DNumbers [35, 75])]
      xScale = GV.PScale [GV.SZero False]
      yScale = GV.PScale [GV.SZero False]
      facetModel = [GV.FName "Demographic Model Type", GV.FmType GV.Nominal]
      encModelMid = GV.position GV.Y ([GV.PName "Demographic Model"
                                     , GV.PmType GV.Quantitative
                                     , GV.PAxis [GV.AxTitle "Demographic Model"]
                                     , GV.PScale [GV.SZero False]
                                     , yScale
                                     ]

--                                     ++ [GV.PScale [if single then GV.SZero False else GV.SDomain (GV.DNumbers [0, 100])]]
                                     )
      encModelLo = GV.position GV.Y [GV.PName "Demographic Model (5% CI)"
                                  , GV.PmType GV.Quantitative
                                  , yScale
                                  , GV.PAxis [GV.AxTitle "Demographic Model"]
                                  ]
      encModelHi = GV.position GV.Y2 [GV.PName "Demographic Model (95% CI)"
                                  , GV.PmType GV.Quantitative
                                  , yScale
                                  , GV.PAxis [GV.AxNoTitle]
                                  ]
      encDaves = GV.position GV.X [GV.PName "Historical Model"
                                  , GV.PmType GV.Quantitative
                                  , xScale
                                  , GV.PAxis [GV.AxTitle "Historical Model"]
                                  ]
      enc45 =  GV.position GV.X [GV.PName "Demographic Model"
                                  , GV.PmType GV.Quantitative
                                  , GV.PAxis [GV.AxNoTitle]
                                  , yScale
                                  , GV.PAxis [GV.AxTitle "Historical Model"]
                                  ]
      encDistrictName = GV.text [GV.TName "District Name", GV.TmType GV.Nominal]
      encTooltips = GV.tooltips [[GV.TName "District", GV.TmType GV.Nominal]
                                , [GV.TName "Historical Model", GV.TmType GV.Quantitative]
                                , [GV.TName "Demographic Model", GV.TmType GV.Quantitative]
                                ]
      encCITooltips = GV.tooltips [[GV.TName "District", GV.TmType GV.Nominal]
                                  , [GV.TName "Historical", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model (5% CI)", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model", GV.TmType GV.Quantitative]
                                  , [GV.TName "Demographic Model (95% CI)", GV.TmType GV.Quantitative]
                                  ]

      facets = GV.facet [GV.RowBy facetModel]
      selection = (GV.selection . GV.select "view" GV.Interval [GV.Encodings [GV.ChX, GV.ChY], GV.BindScales, GV.Clear "click[event.shiftKey]"]) []
      ptEnc = GV.encoding . encModelMid . encDaves . encTooltips
      lineEnc = GV.encoding . encModelMid . enc45
      labelEnc = ptEnc . encDistrictName . encTooltips
      ciEnc = GV.encoding . encModelLo . encModelHi . encDaves . encCITooltips
      ciSpec = GV.asSpec [ciEnc [], GV.mark GV.ErrorBar [GV.MTicks [GV.MColor "black"]]]
      labelSpec = GV.asSpec [labelEnc [], GV.mark GV.Text [GV.MdX 20], makeDistrictName [] ]
      ptSpec = GV.asSpec [selection, ptEnc [], GV.mark GV.Circle []]
      lineSpec = GV.asSpec [lineEnc [], GV.mark GV.Line [GV.MTooltip GV.TTNone]]
      resolve = GV.resolve . GV.resolution (GV.RAxis [(GV.ChY, GV.Shared)])
      finalSpec = if single
                  then [FV.title title, GV.layer [ciSpec, lineSpec, labelSpec, ptSpec], vlData]
                  else [FV.title title, facets, GV.specification (GV.asSpec [GV.layer [ptSpec, ciSpec, lineSpec, labelSpec]]), vlData]
  in FV.configuredVegaLite vc finalSpec --

-- fold CES data over districts
aggregateDistricts :: FL.Fold (F.Record BRE.CCESByCDR) (F.FrameRec (BRE.StateKeyR V.++ PredictorR V.++ BRE.CCESVotingDataR))
aggregateDistricts = FMR.concatFold
                     $ FMR.mapReduceFold
                     FMR.noUnpack
                     (FMR.assignKeysAndData @(BRE.StateKeyR V.++ PredictorR) @BRE.CCESVotingDataR)
                     (FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum)

aggregatePredictors :: FL.Fold (F.Record (BRE.StateKeyR V.++ PredictorR V.++ BRE.CCESVotingDataR)) (F.FrameRec (BRE.StateKeyR V.++ BRE.CCESVotingDataR))
aggregatePredictors = FMR.concatFold
                     $ FMR.mapReduceFold
                     FMR.noUnpack
                     (FMR.assignKeysAndData @BRE.StateKeyR @BRE.CCESVotingDataR)
                     (FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum)

aggregatePredictorsInDistricts ::  FL.Fold (F.Record BRE.CCESByCDR) (F.FrameRec (BRE.CDKeyR V.++ BRE.CCESVotingDataR))
aggregatePredictorsInDistricts = FMR.concatFold
                                 $ FMR.mapReduceFold
                                 FMR.noUnpack
                                 (FMR.assignKeysAndData @BRE.CDKeyR @BRE.CCESVotingDataR)
                                 (FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum)
