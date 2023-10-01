{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnicodeSyntax #-}
{-# LANGUAGE StrictData #-}

module Main
  (main)
where

import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.ElectionTypes as ET
import qualified BlueRipple.Data.GeographicTypes as GT
import qualified BlueRipple.Data.ModelingTypes as MT
import qualified BlueRipple.Data.ACS_PUMS as ACS
import qualified BlueRipple.Data.Loaders.Redistricting as DRA
import qualified BlueRipple.Data.CensusLoaders as BRC
import qualified BlueRipple.Data.CensusTables as BRC
import qualified BlueRipple.Data.DataFrames as BRDF
import qualified BlueRipple.Data.Keyed as Keyed
import qualified BlueRipple.Data.Loaders as BRL
import qualified BlueRipple.Utilities.TableUtils as BR
import qualified Text.Blaze.Html5.Attributes   as BHA

import qualified BlueRipple.Utilities.KnitUtils as BRK
import qualified BlueRipple.Model.Demographic.DataPrep as DDP
import qualified BlueRipple.Model.Election2.DataPrep as DP
import qualified BlueRipple.Model.Election2.ModelCommon as MC
--import qualified BlueRipple.Model.Election2.ModelCommon2 as MC2
import qualified BlueRipple.Model.Election2.ModelRunner as MR
import qualified BlueRipple.Model.Demographic.EnrichCensus as DMC
import qualified BlueRipple.Model.Demographic.DataPrep as CDDP
import qualified BlueRipple.Model.Demographic.TableProducts as DTP

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as KC
import qualified Text.Pandoc.Error as Pandoc
import qualified System.Console.CmdArgs as CmdArgs
import qualified Colonnade as C

--import GHC.TypeLits (Symbol)
import qualified Control.Foldl as FL
import Control.Lens (view, (^.))

import qualified Frames as F
import qualified Data.Text as T
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Map.Merge.Strict as MM
import qualified Data.Set as Set
import qualified Frames.Melt as F
import qualified Frames.MapReduce as FMR
import qualified Frames.Folds as FF
import qualified Frames.Transform as FT
import qualified Frames.Constraints as FC
import qualified Frames.SimpleJoins as FJ
import qualified Frames.Streamly.InCore as FSI
import qualified Frames.Streamly.TH as FSTH
import qualified Frames.Serialize as FS

import Path (Dir, Rel)
import qualified Path
import qualified Numeric
import qualified Stan.ModelBuilder.DesignMatrix as DM

import qualified Data.Map.Strict as M

import qualified Text.Printf as PF
import qualified Graphics.Vega.VegaLite as GV
import qualified Graphics.Vega.VegaLite.Compat as FV
import qualified Graphics.Vega.VegaLite.Configuration as FV
import qualified Graphics.Vega.VegaLite.JSON as VJ

--import Data.Monoid (Sum(getSum))

templateVars ∷ Map String String
templateVars =
  M.fromList
    [ ("lang", "English")
    , ("site-title", "Blue Ripple Politics")
    , ("home-url", "https://www.blueripplepolitics.org")
    --  , ("author"   , T.unpack yamlAuthor)
    ]

pandocTemplate ∷ K.TemplatePath
pandocTemplate = K.FullySpecifiedTemplatePath "pandoc-templates/blueripple_basic.html"

type SLDKeyR = '[GT.StateAbbreviation] V.++ BRC.LDLocationR
type ModeledR = SLDKeyR V.++ '[MR.ModelCI]

dlccVA = [(GT.StateLower,"41","Lily Franklin")
         , (GT.StateUpper,"31", "Russet Perry")
         , (GT.StateUpper, "24", "Monty Mason")
         , (GT.StateUpper, "30", "Danica Roem")
         , (GT.StateUpper, "22", "Aaron Rouse")
         , (GT.StateUpper, "16", "Schuyler VanValkenburg")
         , (GT.StateLower, "94", "Phil Hernandez")
         , (GT.StateLower, "84", "Nadarius Clark")
         , (GT.StateLower, "82", "Kimberly Pope Adams")
         , (GT.StateLower, "71", "Jessica Anderson")
         , (GT.StateLower, "65", "Joshua Cole")
         , (GT.StateLower, "58", "Rodney Willet")
         , (GT.StateLower, "57", "Susanna Gibson")
         , (GT.StateLower, "22", "Joshua Thomas")
         , (GT.StateLower, "89", "Karen Jenkins")
         ]
main :: IO ()
main = do

  cmdLine ← CmdArgs.cmdArgsRun BR.commandLine
  pandocWriterConfig ←
    K.mkPandocWriterConfig
    pandocTemplate
    templateVars
    (BRK.brWriterOptionsF . K.mindocOptionsF)
  let cacheDir = ".flat-kh-cache"
      knitConfig ∷ K.KnitConfig BRK.SerializerC BRK.CacheData Text =
        (K.defaultKnitConfig $ Just cacheDir)
          { K.outerLogPrefix = Just "2023-StateLeg"
          , K.logIf = BR.knitLogSeverity $ BR.logLevel cmdLine -- K.logDiagnostic
          , K.pandocWriterConfig = pandocWriterConfig
          , K.serializeDict = BRK.flatSerializeDict
          , K.persistCache = KC.persistStrictByteString (\t → toString (cacheDir <> "/" <> t))
          }
  resE ← K.knitHtmls knitConfig $ do
    K.logLE K.Info $ "Command Line: " <> show cmdLine
    let postInfo = BR.PostInfo (BR.postStage cmdLine) (BR.PubTimes BR.Unpublished Nothing)
        dmr = MC.tDesignMatrixRow_d
        survey = MC.CESSurvey
        aggregation = MC.WeightedAggregation MC.ContinuousBinomial MC.NoAchenHur
        alphaModel = MC.St_A_S_E_R_ER_StR_StER
        psT = MC.NoPSTargets --, MC.PSTargets]
    rawCES_C <- DP.cesCountedDemPresVotesByCD False
    cpCES_C <-  DP.cachedPreppedCES (Right "model/election2/test/CESTurnoutModelDataRaw.bin") rawCES_C
    rawCPS_C <- DP.cpsCountedTurnoutByState
    cpCPS_C <- DP.cachedPreppedCPS (Right "model/election2/test/CPSTurnoutModelDataRaw.bin") rawCPS_C
    let modelDirE = Right "model/election2/stan/"
        cacheDirE = Right "model/election2/"

    let state = "VA"
    modelPostPaths <- postPaths state cmdLine

    let psDataForState :: Text -> DP.PSData SLDKeyR -> DP.PSData SLDKeyR
        psDataForState sa = DP.PSData . F.filterFrame ((== sa) . view GT.stateAbbreviation) . DP.unPSData

    BRK.brNewPost modelPostPaths postInfo state $ do
      presidentialElections_C <- BRL.presidentialByStateFrame
      modeledACSBySLDPSData_C <- modeledACSBySLD cmdLine
      let stateSLDs_C = fmap (psDataForState state) modeledACSBySLDPSData_C
      sldDemographicSummary <- FL.fold (DP.summarizeASER_Fld @[GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName]) . DP.unPSData <$> K.ignoreCacheTime stateSLDs_C
      let turnoutModel gqName agg am pt = MR.runTurnoutModelAH @SLDKeyR 2020 modelDirE cacheDirE gqName cmdLine survey agg (contramap F.rcast dmr) pt am "AllCells"
          prefModel gqName agg am pt = MR.runPrefModelAH @SLDKeyR 2020 modelDirE cacheDirE gqName cmdLine agg (contramap F.rcast dmr) pt am 2020 presidentialElections_C "AllCells"
          dVSModel gqName agg am pt
            = MR.runFullModelAH @SLDKeyR 2020 modelDirE cacheDirE gqName cmdLine survey agg (contramap F.rcast dmr) pt am 2020 presidentialElections_C
          g f (a, b) = f b >>= pure . (a, )
          h f = traverse (g f)
--      modeledTurnoutMap <- K.ignoreCacheTimeM $ turnoutModel (state <> "_SLD") aggregation alphaModel psT stateSLDs_C
--      modeledPrefMap <- K.ignoreCacheTimeM $ prefModel (state <> "_SLD") aggregation alphaModel psT stateSLDs_C
      modeledDVSMap <- K.ignoreCacheTimeM $ dVSModel (state <> "_SLD") aggregation alphaModel psT stateSLDs_C
      let modeledDVs = modeledMapToFrame modeledDVSMap
      dra <- do
        allPlansMap <- DRA.allPassedSLDPlans
        upper <- K.ignoreCacheTimeM $ DRA.lookupAndLoadRedistrictingPlanAnalysis allPlansMap (DRA.redistrictingPlanId state "Passed" GT.StateUpper)
        lower <- K.ignoreCacheTimeM $ DRA.lookupAndLoadRedistrictingPlanAnalysis allPlansMap (DRA.redistrictingPlanId state "Passed" GT.StateLower)
        pure $ upper <> lower
      let (modeledAndDRA, missingModelDRA, missingSummary)
            = FJ.leftJoin3WithMissing @[GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName] modeledDVs dra sldDemographicSummary
      when (not $ null missingModelDRA) $ K.knitError $ "br-2023-StateLeg: Missing keys in modeledDVs/dra join: " <> show missingModelDRA
      when (not $ null missingSummary) $ K.knitError $ "br-2023-StateLeg: Missing keys in modeledDVs+dra/sumamry join: " <> show missingSummary
--      BRK.logFrame modeledAndDRA

      compChart <- modelDRAComparisonChart modelPostPaths postInfo (state <> "comp") (state <> ": model vs historical (DRA)")
                   (FV.ViewConfig 500 500 10) modeledAndDRA
      _ <- K.addHvega Nothing Nothing compChart
      let delta r = 100 * ((MT.ciMid $ r ^. MR.modelCI) -  r ^. ET.demShare)
      geoDeltaChartL <- geoCompChart modelPostPaths postInfo (state <> "_geoDeltaL") (state <> ": model - historical")
                       (FV.ViewConfig 500 300 10) "VA" GT.StateLower ("delta", delta) modeledAndDRA
      _ <- K.addHvega Nothing Nothing geoDeltaChartL
      geoDeltaChartU <- geoCompChart modelPostPaths postInfo (state <> "_geoDeltaU") (state <> ": model - historical")
                       (FV.ViewConfig 500 300 10) "VA" GT.StateUpper ("delta", delta) modeledAndDRA
      _ <- K.addHvega Nothing Nothing geoDeltaChartU
      geoCompChart modelPostPaths postInfo (state <> "_geoDensityL") (state <> ": log density")
        (FV.ViewConfig 500 300 10) "VA" GT.StateLower ("log density", Numeric.log . view DT.pWPopPerSqMile) modeledAndDRA
        >>= K.addHvega Nothing Nothing
      geoCompChart modelPostPaths postInfo (state <> "_geoAgeL") (state <> ": % Over 45")
        (FV.ViewConfig 500 300 10) "VA" GT.StateLower ("Over 45 (%)", \r -> 100 * (r ^. DP.frac45To64 + r ^. DP.frac65plus)) modeledAndDRA
        >>= K.addHvega Nothing Nothing
      geoCompChart modelPostPaths postInfo (state <> "_geoCGradL") (state <> ": % College Grad")
        (FV.ViewConfig 500 300 10) "VA" GT.StateLower ("College Grad (%)", \r -> 100 * (r ^. DP.fracCollegeGrad)) modeledAndDRA
        >>= K.addHvega Nothing Nothing
      let byDistrictName r1 r2 = GT.districtNameCompare (r1 ^. GT.districtName) (r2 ^. GT.districtName)
          draCompetitive r = let x = r ^. ET.demShare in (x > 0.42 && x < 0.58)
          dlcc = dlccVA
          toDistrict (x, y, _) = (x, y)
          isDLCC r = (r ^. GT.districtTypeC, r ^. GT.districtName) `elem` fmap toDistrict dlcc
          bordered c = "border: 3px solid " <> c
          dlccChosenCS = bordered "purple" `BR.cellStyleIf` \r h -> (isDLCC r && h == "District")
          longShot ci = MT.ciUpper ci < 0.48
          leanR ci = MT.ciMid ci < 0.5 && MT.ciUpper ci >= 0.48
          leanD ci = MT.ciMid ci >= 0.5 && MT.ciLower ci <= 0.52
          safeD ci = MT.ciLower ci > 0.52
          mi = F.rgetField @MR.ModelCI
          eRes = F.rgetField @ET.DemShare
          longShotCS  = bordered "red" `BR.cellStyleIf` \r h -> longShot (mi r) && h == "95%"
          leanRCS =  bordered "pink" `BR.cellStyleIf` \r h -> leanR (mi r) && h `elem` ["95%", "50%"]
          leanDCS = bordered "skyblue" `BR.cellStyleIf` \r h -> leanD (mi r) && h `elem` ["5%","50%"]
          safeDCS = bordered "blue"  `BR.cellStyleIf` \r h -> safeD (mi r) && h == "5%"
          resLongShotCS = bordered "red" `BR.cellStyleIf` \r h -> eRes r < 0.48 && T.isPrefixOf "2019" h
          resLeanRCS = bordered "pink" `BR.cellStyleIf` \r h -> eRes r >= 0.48 && eRes r < 0.5 && T.isPrefixOf "2019" h
          resLeanDCS = bordered "skyblue" `BR.cellStyleIf` \r h -> eRes r >= 0.5 && eRes r <= 0.52 && T.isPrefixOf "2019" h
          resSafeDCS = bordered "blue" `BR.cellStyleIf` \r h -> eRes r > 0.52 && T.isPrefixOf "2019" h
          cellStyle = mconcat [dlccChosenCS, longShotCS, leanRCS, leanDCS, safeDCS]
      BR.brAddRawHtmlTable "VA Model (2020 data): Senate" (BHA.class_ "brTable") (sldColonnade cellStyle)
        $ sortBy byDistrictName $ FL.fold FL.list
        $ F.filterFrame draCompetitive
        $ F.filterFrame ((== GT.StateUpper) . view GT.districtTypeC) modeledAndDRA
      BR.brAddRawHtmlTable "VA Model (2020 data): House" (BHA.class_ "brTable") (sldColonnade cellStyle)
        $ sortBy byDistrictName $ FL.fold FL.list
        $ F.filterFrame draCompetitive
        $ F.filterFrame ((== GT.StateLower) . view GT.districtTypeC) modeledAndDRA
      pure ()
    pure ()
  pure ()
  case resE of
    Right namedDocs →
      K.writeAllPandocResultsWithInfoAsHtml "" namedDocs
    Left err → putTextLn $ "Pandoc Error: " <> Pandoc.renderError err

sldColonnade :: (FC.ElemsOf rs [GT.StateAbbreviation, GT.DistrictTypeC, GT.DistrictName, MR.ModelCI, ET.DemShare])
             => BR.CellStyle (F.Record rs) [Char] -> C.Colonnade C.Headed (F.Record rs) K.Cell
sldColonnade cas =
  let state = F.rgetField @GT.StateAbbreviation
      dType r = case (r ^. GT.districtTypeC) of
        GT.StateUpper -> "Upper"
        GT.StateLower -> "Lower"
        _ -> "Not State Leg!"
      dName = F.rgetField @GT.DistrictName
      fullName = \r -> (dType r <> "-" <> dName r)
      share5 = MT.ciLower . F.rgetField @MR.ModelCI
      share50 = MT.ciMid . F.rgetField @MR.ModelCI
      share95 = MT.ciUpper . F.rgetField @MR.ModelCI
  in C.headed "State" (BR.toCell cas "State" "State" (BR.textToStyledHtml . state))
     <> C.headed "District" (BR.toCell cas "District" "District" (BR.textToStyledHtml . fullName))
     <> C.headed "Historical" (BR.toCell cas "Historical" "Historical" (BR.numberToStyledHtml "%2.2f" . (100*) . F.rgetField @ET.DemShare))
     <> C.headed "5%" (BR.toCell cas "5%" "5%" (BR.numberToStyledHtml "%2.2f" . (100*) . share5))
     <> C.headed "50%" (BR.toCell cas "50%" "50%" (BR.numberToStyledHtml "%2.2f" . (100*) . share50))
     <> C.headed "95%" (BR.toCell cas "95%" "95%" (BR.numberToStyledHtml "%2.2f" . (100*) . share95))

modelDRAComparisonChart :: (K.KnitEffects r
                           , FC.ElemsOf rs [GT.StateAbbreviation, MR.ModelCI, ET.DemShare, GT.DistrictName, GT.DistrictTypeC]
                           )
                        => BR.PostPaths Path.Abs -> BR.PostInfo -> Text -> Text -> FV.ViewConfig -> F.FrameRec rs -> K.Sem r GV.VegaLite
modelDRAComparisonChart pp pi chartID title vc rows = do
  let colData r = [("State", GV.Str $ r ^. GT.stateAbbreviation)
                  ,("District", GV.Str $ show (r ^. GT.districtTypeC) <> "-" <> r ^. GT.districtName)
                  ,("Model_Lo" , GV.Number $ MT.ciLower $ r ^. MR.modelCI)
                  ,("Model" , GV.Number $ MT.ciMid $ r ^. MR.modelCI)
                  ,("Model_Hi" , GV.Number $ MT.ciUpper $ r ^. MR.modelCI)
                  ,("Historical", GV.Number $ r ^. ET.demShare)
                  ]
      jsonRows = FL.fold (VJ.rowsToJSON colData [] Nothing) rows
  jsonFilePrefix <- K.getNextUnusedId $ ("2023-StateLeg_" <> chartID)
  jsonUrl <-  BRK.brAddJSON pp pi jsonFilePrefix jsonRows
  let vlData = GV.dataFromUrl jsonUrl [GV.JSON "values"]
      encHistorical = GV.position GV.X [GV.PName "Historical", GV.PmType GV.Quantitative,  GV.PScale [GV.SZero False]]
      encModel = GV.position GV.Y [GV.PName "Model", GV.PmType GV.Quantitative,  GV.PScale [GV.SZero False]]
      markMid = GV.mark GV.Circle [GV.MTooltip GV.TTData]
      midSpec = GV.asSpec [(GV.encoding . encHistorical . encModel) [], markMid]
      encModelLo = GV.position GV.Y [GV.PName "Model_Lo", GV.PmType GV.Quantitative,  GV.PScale [GV.SZero False]]
      encModelHi = GV.position GV.Y2 [GV.PName "Model_Hi", GV.PmType GV.Quantitative,  GV.PScale [GV.SZero False]]
      markError = GV.mark GV.ErrorBar [GV.MTooltip GV.TTEncoding]
      errorSpec = GV.asSpec [(GV.encoding . encHistorical . encModelLo . encModelHi) [], markError]
      encHistoricalY = GV.position GV.Y [GV.PName "Historical", GV.PmType GV.Quantitative,  GV.PScale [GV.SZero False]]
      lineSpec = GV.asSpec [(GV.encoding . encHistorical . encHistoricalY) [], GV.mark GV.Line []]
      layers = GV.layer [midSpec, errorSpec, lineSpec]
  pure $  FV.configuredVegaLite vc [FV.title title
                                  , layers
                                  , vlData
                                  ]

geoCompChart :: (K.KnitEffects r
                , FC.ElemsOf rs [MR.ModelCI, ET.DemShare, GT.DistrictName, GT.DistrictTypeC]
                , FSI.RecVec rs
                 )
              => BR.PostPaths Path.Abs
              -> BR.PostInfo
              -> Text
              -> Text
              -> FV.ViewConfig
              -> Text
              -> GT.DistrictType
              -> (Text, F.Record rs -> Double)
              -> F.FrameRec rs
              -> K.Sem r GV.VegaLite
geoCompChart pp pi chartID title vc sa dType (label, f) rows = do
  let colData r = [ ("District", GV.Str $ r ^. GT.districtName)
                  , ("Model" , GV.Number $ MT.ciMid $ r ^. MR.modelCI)
                  , ("Historical", GV.Number $ r ^. ET.demShare)
                  , (label, GV.Number $ f r) --100 * ((MT.ciMid $ r ^. MR.modelCI) -  r ^. ET.demShare))
                  ]
      jsonRows = FL.fold (VJ.rowsToJSON colData [] Nothing) $ F.filterFrame ((== dType) . view GT.districtTypeC)rows
  jsonFilePrefix <- K.getNextUnusedId $ ("2023-StateLeg_" <> chartID)
  jsonDataUrl <-  BRK.brAddJSON pp pi jsonFilePrefix jsonRows
  (geoJsonPrefix, titleSuffix) <- case dType of
    GT.StateUpper -> pure $ (sa <> "_2022_sldu", " (Upper Chamber)")
    GT.StateLower -> pure $ (sa <> "_2022_sldl", " (Lower Chamber)")
    _ -> K.knitError $ "modelGeoChart: Bad district type (" <> show dType <> ") specified"

  geoJsonSrc <- K.liftKnit @IO $ Path.parseAbsFile $ toString $ "/Users/adam/BlueRipple/GeoData/input_data/StateLegDistricts/" <> sa <> "/" <> geoJsonPrefix <> "_topo.json"
  jsonGeoUrl <- BRK.brCopyDataForPost pp pi BRK.LeaveExisting geoJsonSrc Nothing
  let rowData = GV.dataFromUrl jsonDataUrl [GV.JSON "values"]
      geoData = GV.dataFromUrl jsonGeoUrl [GV.TopojsonFeature geoJsonPrefix]
      encQty = GV.color [GV.MName label, GV.MmType GV.Quantitative]
      encoding = (GV.encoding . encQty) []
      tLookup = (GV.transform . GV.lookup "properties.NAME" rowData "District" (GV.LuFields [label])) []
      mark = GV.mark GV.Geoshape [GV.MTooltip GV.TTData]
      projection = GV.projection [GV.PrType GV.Identity, GV.PrReflectY True]
  pure $ FV.configuredVegaLite vc [FV.title (title <> titleSuffix), geoData, tLookup, projection, encoding, mark]





modeledMapToFrame :: MC.PSMap SLDKeyR MT.ConfidenceInterval -> F.FrameRec ModeledR
modeledMapToFrame = F.toFrame . fmap (\(k, ci) -> k F.<+> FT.recordSingleton @MR.ModelCI ci) . M.toList . MC.unPSMap

modeledACSBySLD :: (K.KnitEffects r, BRK.CacheEffects r) => BR.CommandLine -> K.Sem r (K.ActionWithCacheTime r (DP.PSData SLDKeyR))
modeledACSBySLD cmdLine = do
  (jointFromMarginalPredictorCSR_ASR_C, _, _) <- CDDP.cachedACSa5ByPUMA  ACS.acs1Yr2012_21 2021 -- most recent available
                                                 >>= DMC.predictorModel3 @'[DT.CitizenC] @'[DT.Age5C] @DMC.SRCA @DMC.SR
                                                 (Right "model/demographic/csr_asr_PUMA") "CSR_ASR_ByPUMA"
                                                 cmdLine . fmap (fmap F.rcast)
  (jointFromMarginalPredictorCASR_ASE_C, _, _) <- CDDP.cachedACSa5ByPUMA ACS.acs1Yr2012_21 2021 -- most recent available
                                                  >>= DMC.predictorModel3 @[DT.CitizenC, DT.Race5C] @'[DT.Education4C] @DMC.ASCRE @DMC.AS
                                                  (Right "model/demographic/casr_ase_PUMA") "CASR_SER_ByPUMA"
                                                  cmdLine . fmap (fmap F.rcast)
  (acsCASERBySLD, _products) <- BRC.censusTablesFor2022SLD_ACS2021
                                >>= DMC.predictedCensusCASER' (DTP.viaNearestOnSimplex) False "model/election2/sldDemographics"
                                jointFromMarginalPredictorCSR_ASR_C
                                jointFromMarginalPredictorCASR_ASE_C
  BRK.retrieveOrMakeD "model/election2/data/sldPSData.bin" acsCASERBySLD
    $ \x -> DP.PSData . fmap F.rcast <$> (BRL.addStateAbbrUsingFIPS $ F.filterFrame ((== DT.Citizen) . view DT.citizenC) x)
{-
modeledACSBySLD' :: (K.KnitEffects r, BRK.CacheEffects r) => BR.CommandLine -> K.Sem r (K.ActionWithCacheTime r (DP.PSData SLDKeyR))
modeledACSBySLD' cmdLine = do
  (jointFromMarginalPredictorCSR_ASR_C, _, _) <- CDDP.cachedACSa5ByPUMA  ACS.acs1Yr2012_21 2021 -- most recent available
                                                 >>= DMC.predictorModel3 @'[DT.CitizenC] @'[DT.Age5C] @DMC.SRCA @DMC.SR
                                                 (Right "model/demographic/csr_asr_PUMA") "CSR_ASR_ByPUMA"
                                                 cmdLine . fmap (fmap F.rcast)
  (jointFromMarginalPredictorCASR_ASE_C, _, _) <- CDDP.cachedACSa5ByPUMA ACS.acs1Yr2012_21 2021 -- most recent available
                                                  >>= DMC.predictorModel3 @[DT.CitizenC, DT.Race5C] @'[DT.Education4C] @DMC.ASCRE @DMC.AS
                                                  (Right "model/demographic/casr_ase_PUMA") "CASR_SER_ByPUMA"
                                                  cmdLine . fmap (fmap F.rcast)
  (acsCASERBySLD, _products) <- BRC.censusTablesFor2022SLD_ACS2021
                                >>= DMC.predictedCensusCASER' (DTP.viaNearestOnSimplex) True "test"
                                jointFromMarginalPredictorCSR_ASR_C
                                jointFromMarginalPredictorCASR_ASE_C
  BRK.retrieveOrMakeD "test/data/sldPSData.bin" acsCASERBySLD
    $ \x -> DP.PSData . fmap F.rcast <$> (BRL.addStateAbbrUsingFIPS $ F.filterFrame ((== DT.Citizen) . view DT.citizenC) x)

testCensusPredictions :: (K.KnitEffects r, BRK.CacheEffects r) => BR.CommandLine -> K.Sem r ()
testCensusPredictions cmdLine = do
  let densityFilter r = let x = r ^. DT.pWPopPerSqMile in x <= 0 || x > 1e6
  inputFilteredASE <- F.filterFrame densityFilter . BRC.ageSexEducation <$> K.ignoreCacheTimeM BRC.censusTablesFor2022SLD_ACS2021
  K.logLE K.Info "Weird densities in Input?"
  K.logLE K.Info "CSR"
  (F.filterFrame densityFilter . BRC.citizenshipSexRace <$> K.ignoreCacheTimeM BRC.censusTablesFor2022SLD_ACS2021) >>= BRK.logFrame
  K.logLE K.Info "ASR"
  (F.filterFrame densityFilter . BRC.ageSexRace <$> K.ignoreCacheTimeM BRC.censusTablesFor2022SLD_ACS2021) >>= BRK.logFrame
  K.logLE K.Info "ASE"
  (F.filterFrame densityFilter . BRC.ageSexEducation <$> K.ignoreCacheTimeM BRC.censusTablesFor2022SLD_ACS2021) >>= BRK.logFrame
  result <- K.ignoreCacheTimeM $  modeledACSBySLD' cmdLine
--  K.logLE K.Info "Result"
--  BRK.logFrame $ F.filterFrame densityFilter $ DP.unPSData result
  pure ()
-}

postDir ∷ Path.Path Rel Dir
postDir = [Path.reldir|br-2023-StateLeg/posts|]

postLocalDraft
  ∷ Path.Path Rel Dir
  → Maybe (Path.Path Rel Dir)
  → Path.Path Rel Dir
postLocalDraft p mRSD = case mRSD of
  Nothing → postDir BR.</> p BR.</> [Path.reldir|draft|]
  Just rsd → postDir BR.</> p BR.</> rsd

postInputs ∷ Path.Path Rel Dir → Path.Path Rel Dir
postInputs p = postDir BR.</> p BR.</> [Path.reldir|inputs|]

sharedInputs ∷ Path.Path Rel Dir
sharedInputs = postDir BR.</> [Path.reldir|Shared|] BR.</> [Path.reldir|inputs|]

postOnline ∷ Path.Path Rel t → Path.Path Rel t
postOnline p = [Path.reldir|research/Election|] BR.</> p

postPaths
  ∷ (K.KnitEffects r)
  ⇒ Text
  → BR.CommandLine
  → K.Sem r (BR.PostPaths BR.Abs)
postPaths t cmdLine = do
  let mRelSubDir = case cmdLine of
        BR.CLLocalDraft _ _ mS _ → maybe Nothing BR.parseRelDir $ fmap toString mS
        _ → Nothing
  postSpecificP ← K.knitEither $ first show $ Path.parseRelDir $ toString t
  BR.postPaths
    BR.defaultLocalRoot
    sharedInputs
    (postInputs postSpecificP)
    (postLocalDraft postSpecificP mRelSubDir)
    (postOnline postSpecificP)
