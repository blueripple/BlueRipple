{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -O0 #-}

module BlueRipple.Model.House.ElectionResult where

import Prelude hiding (pred)
import qualified BlueRipple.Configuration as BR
import qualified BlueRipple.Data.ACS_PUMS as PUMS
import qualified BlueRipple.Data.CCES as CCES
import qualified BlueRipple.Data.CPSVoterPUMS as CPS
import qualified BlueRipple.Data.CensusTables as Census
import qualified BlueRipple.Data.CensusLoaders as Census
import qualified BlueRipple.Data.CountFolds as BRCF
import qualified BlueRipple.Data.DataFrames as BR
import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.ElectionTypes as ET
import qualified BlueRipple.Data.ModelingTypes as MT
import qualified BlueRipple.Data.Keyed as BRK
import qualified BlueRipple.Data.Loaders as BR
import qualified BlueRipple.Model.TurnoutAdjustment as BRTA
import qualified BlueRipple.Model.PostStratify as BRPS
import qualified BlueRipple.Utilities.KnitUtils as BR
import qualified BlueRipple.Utilities.FramesUtils as BRF
import qualified BlueRipple.Model.StanMRP as MRP
import qualified Numeric
import qualified CmdStan as CS
import qualified Control.Foldl as FL
import qualified Data.Aeson as A
import qualified Data.List as List
import qualified Data.Map as M
import qualified Data.IntMap as IM
import qualified Data.Set as Set
import Data.String.Here (here)
import qualified Data.Serialize                as S
import qualified Data.Text as T
import qualified Data.Vector as Vec
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vector as Vector
import qualified Flat
import qualified Frames as F
import qualified Frames.Conversion as FC
import qualified Frames.Melt as F
import qualified Frames.InCore as FI
import qualified Frames.Folds as FF
import qualified Frames.MapReduce as FMR
import qualified Frames.Serialize as FS
import qualified Frames.SimpleJoins as FJ
import qualified Frames.Transform as FT
import GHC.Generics (Generic)
import qualified Data.MapRow as MapRow
import qualified Knit.Effect.AtomicCache as K hiding (retrieveOrMake)
import qualified Knit.Report as K
import qualified Knit.Utilities.Streamly as K
import qualified Numeric.Foldl as NFL
import qualified Optics
import qualified Stan.JSON as SJ
import qualified Stan.ModelBuilder as SB
import qualified Stan.ModelBuilder.BuildingBlocks as SB
import qualified Stan.ModelBuilder.GroupModel as SB
import qualified Stan.ModelBuilder.FixedEffects as SFE
import qualified Stan.ModelConfig as SC
import qualified Stan.ModelRunner as SM
import qualified Stan.Parameters as SP
import qualified Stan.RScriptBuilder as SR

type FracUnder45 = "FracUnder45" F.:-> Double

type FracFemale = "FracFemale" F.:-> Double

type FracGrad = "FracGrad" F.:-> Double

type FracWhiteNonHispanic = "FracWhiteNonHispanic" F.:-> Double
type FracWhiteHispanic = "FracWhiteHispanic" F.:-> Double
type FracNonWhiteHispanic = "FracNonWhiteHispanic" F.:-> Double
type FracBlack = "FracBlack" F.:-> Double
type FracAsian = "FracAsian" F.:-> Double
type FracOther = "FracOther" F.:-> Double
type FracWhiteGrad = "FracWhiteGrad" F.:-> Double -- fraction of white people who are college grads

type FracCitizen = "FracCitizen" F.:-> Double

type StateKeyR = [BR.Year, BR.StateAbbreviation]
type CDKeyR = StateKeyR V.++ '[BR.CongressionalDistrict]

type DemographicsR =
  [ FracUnder45
  , FracFemale
  , FracGrad
  , FracWhiteNonHispanic
  , FracWhiteHispanic
  , FracNonWhiteHispanic
  , FracBlack
  , FracAsian
  , FracOther
  , FracWhiteGrad
  , DT.AvgIncome
  , DT.PopPerSqMile
  , PUMS.Citizens
  ]

type DVotes = "DVotes" F.:-> Int
type RVotes = "RVotes" F.:-> Int
type TVotes = "TVotes" F.:-> Int
type Voted = "Voted" F.:-> Int
type HouseVotes = "HouseVotes" F.:-> Int
type HouseDVotes = "HouseDVotes" F.:-> Int
type PresVotes = "PresVotes" F.:-> Int
type PresDVotes = "PresDVotes" F.:-> Int

-- +1 for Dem incumbent, 0 for no incumbent, -1 for Rep incumbent
type Incumbency = "Incumbency" F.:-> Int
type ElectionR = [Incumbency, DVotes, RVotes, TVotes]
type ElectionPredictorR = [FracUnder45
                          , FracFemale
                          , FracGrad
                          , FracWhiteNonHispanic
                          , FracWhiteHispanic
                          , FracNonWhiteHispanic
                          , FracBlack
                          , FracAsian
                          , FracOther
                          , FracWhiteGrad
                          , DT.AvgIncome
                          , DT.PopPerSqMile]
type HouseElectionDataR = CDKeyR V.++ DemographicsR V.++ ElectionR
type HouseElectionData = F.FrameRec HouseElectionDataR

type SenateElectionDataR = SenateRaceKeyR V.++ DemographicsR V.++ ElectionR
type SenateElectionData = F.FrameRec SenateElectionDataR

type PresidentialElectionDataR = StateKeyR V.++ DemographicsR V.++ ElectionR
type PresidentialElectionData  = F.FrameRec PresidentialElectionDataR


-- CCES data
type Surveyed = "Surveyed" F.:-> Int -- total people in each bucket
type CCESVotingDataR = [Surveyed, Voted, HouseVotes, HouseDVotes, PresVotes, PresDVotes]
type CCESByCDR = CDKeyR V.++ [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC] V.++ CCESVotingDataR
type CCESDataR = CCESByCDR V.++ [Incumbency, DT.AvgIncome, DT.PopPerSqMile]
type CCESPredictorR = [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC, DT.AvgIncome, DT.PopPerSqMile]
type CCESData = F.FrameRec CCESDataR

data DemographicSource = DS_1YRACSPUMS | DS_5YRACSTracts deriving (Show, Eq, Ord)
demographicSourceLabel :: DemographicSource -> Text
demographicSourceLabel DS_1YRACSPUMS = "ACS1P"
demographicSourceLabel DS_5YRACSTracts = "ACS5T"

data HouseModelData = HouseModelData { houseElectionData :: HouseElectionData
                                     , senateElectionData :: SenateElectionData
                                     , presidentialElectionData :: PresidentialElectionData
                                     , ccesData :: CCESData
                                     } deriving (Generic)

houseRaceKey :: F.Record HouseElectionDataR -> F.Record CDKeyR
houseRaceKey = F.rcast

senateRaceKey :: F.Record SenateElectionDataR -> F.Record SenateRaceKeyR
senateRaceKey = F.rcast

presidentialRaceKey :: F.Record PresidentialElectionDataR -> F.Record StateKeyR
presidentialRaceKey = F.rcast

-- frames are not directly serializable so we have to do...shenanigans
instance S.Serialize HouseModelData where
  put (HouseModelData h s p c) = S.put (FS.SFrame h, FS.SFrame s, FS.SFrame p, FS.SFrame c)
  get = (\(h, s, p, c) -> HouseModelData (FS.unSFrame h) (FS.unSFrame s) (FS.unSFrame p) (FS.unSFrame c)) <$> S.get

instance Flat.Flat HouseModelData where
  size (HouseModelData h s p c) n = Flat.size (FS.SFrame h, FS.SFrame s, FS.SFrame p, FS.SFrame c) n
  encode (HouseModelData h s p c) = Flat.encode (FS.SFrame h, FS.SFrame s, FS.SFrame p, FS.SFrame c)
  decode = (\(h, s, p, c) -> HouseModelData (FS.unSFrame h) (FS.unSFrame s) (FS.unSFrame p) (FS.unSFrame c)) <$> Flat.decode

type PUMSDataR = [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.RaceAlone4C, DT.HispC, DT.AvgIncome, DT.PopPerSqMile, PUMS.Citizens, PUMS.NonCitizens]

type PUMSByCDR = CDKeyR V.++ PUMSDataR
type PUMSByCD = F.FrameRec PUMSByCDR

-- unweighted, which we address via post-stratification
type CPSPredictorR = [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.RaceAlone4C, DT.HispC]
type CPSVDataR  = CPSPredictorR V.++ BRCF.CountCols
type CPSVByCDR = CDKeyR V.++ CPSVDataR

type DistrictDataR = CDKeyR V.++ [DT.PopPerSqMile, DT.AvgIncome] V.++ ElectionR
type DistrictDemDataR = CDKeyR V.++ [PUMS.Citizens, DT.PopPerSqMile, DT.AvgIncome]
type AllCatR = '[BR.Year] V.++ CPSPredictorR
data CCESAndPUMS = CCESAndPUMS { ccesRows :: F.FrameRec CCESByCDR
                               , cpsVRows :: F.FrameRec CPSVByCDR
                               , pumsRows :: F.FrameRec PUMSByCDR
                               , districtRows :: F.FrameRec DistrictDemDataR
--                               , allCategoriesRows :: F.FrameRec AllCatR
                               } deriving (Generic)

ccesAndPUMSForYear :: Int -> CCESAndPUMS -> CCESAndPUMS
ccesAndPUMSForYear y = ccesAndPUMSForYears [y]

ccesAndPUMSForYears :: [Int] -> CCESAndPUMS -> CCESAndPUMS
ccesAndPUMSForYears ys (CCESAndPUMS cces cpsV pums dist) =
  let f :: (FI.RecVec rs, F.ElemOf rs BR.Year) => F.FrameRec rs -> F.FrameRec rs
      f = F.filterFrame ((`elem` ys) . F.rgetField @BR.Year)
  in CCESAndPUMS (f cces) (f cpsV) (f pums) (f dist)


instance S.Serialize CCESAndPUMS where
  put (CCESAndPUMS cces cpsV pums dist) = S.put (FS.SFrame cces, FS.SFrame cpsV, FS.SFrame pums, FS.SFrame dist)
  get = (\(cces, cpsV, pums, dist) -> CCESAndPUMS (FS.unSFrame cces) (FS.unSFrame cpsV) (FS.unSFrame pums) (FS.unSFrame dist)) <$> S.get

instance Flat.Flat CCESAndPUMS where
  size (CCESAndPUMS cces cpsV pums dist) n = Flat.size (FS.SFrame cces, FS.SFrame cpsV, FS.SFrame pums, FS.SFrame dist) n
  encode (CCESAndPUMS cces cpsV pums dist) = Flat.encode (FS.SFrame cces, FS.SFrame cpsV, FS.SFrame pums, FS.SFrame dist)
  decode = (\(cces, cpsV, pums, dist) -> CCESAndPUMS (FS.unSFrame cces) (FS.unSFrame cpsV) (FS.unSFrame pums) (FS.unSFrame dist)) <$> Flat.decode

pumsMR :: forall ks f m.(Foldable f
                        , Ord (F.Record ks)
                        , FI.RecVec (ks V.++ DemographicsR)
                        , ks F.⊆ (ks V.++ PUMSDataR)
                        , F.ElemOf (ks V.++ PUMSDataR) DT.AvgIncome
                        , F.ElemOf (ks V.++ PUMSDataR) PUMS.Citizens
                        , F.ElemOf (ks V.++ PUMSDataR) DT.CollegeGradC
                        , F.ElemOf (ks V.++ PUMSDataR) DT.HispC
                        , F.ElemOf (ks V.++ PUMSDataR) PUMS.NonCitizens
                        , F.ElemOf (ks V.++ PUMSDataR) DT.PopPerSqMile
                        , F.ElemOf (ks V.++ PUMSDataR) DT.RaceAlone4C
                        , F.ElemOf (ks V.++ PUMSDataR) DT.SexC
                        , F.ElemOf (ks V.++ PUMSDataR) DT.SimpleAgeC
                        )
       => f (F.Record (ks V.++ PUMSDataR))
       -> (F.FrameRec (ks V.++ DemographicsR))
pumsMR = runIdentity
         . BRF.frameCompactMRM
         FMR.noUnpack
         (FMR.assignKeysAndData @ks)
         pumsDataF

pumsDataF ::
  FL.Fold
    (F.Record PUMSDataR)
    (F.Record DemographicsR)
pumsDataF =
  let cit = F.rgetField @PUMS.Citizens
      citF = FL.premap cit FL.sum
      intRatio x y = realToFrac x / realToFrac y
      fracF f = intRatio <$> FL.prefilter f citF <*> citF
      citWgtdSumF f = FL.premap (\r -> realToFrac (cit r) * f r) FL.sum
      citWgtdF f = (/) <$> citWgtdSumF f <*> fmap realToFrac citF
      race4A = F.rgetField @DT.RaceAlone4C
      hisp = F.rgetField @DT.HispC
      wnh r = race4A r == DT.RA4_White && hisp r == DT.NonHispanic
      wh r = race4A r == DT.RA4_White && hisp r == DT.Hispanic
      nwh r = race4A r /= DT.RA4_White && hisp r == DT.Hispanic -- this overlaps other categories
      black r = race4A r == DT.RA4_Black
      asian r = race4A r == DT.RA4_Asian
      other r = race4A r == DT.RA4_Other
      white r = race4A r == DT.RA4_White
      whiteGrad r = (white r) && (F.rgetField @DT.CollegeGradC r == DT.Grad)
  in FF.sequenceRecFold $
     FF.toFoldRecord (fracF ((== DT.Under) . F.rgetField @DT.SimpleAgeC))
     V.:& FF.toFoldRecord (fracF ((== DT.Female) . F.rgetField @DT.SexC))
     V.:& FF.toFoldRecord (fracF ((== DT.Grad) . F.rgetField @DT.CollegeGradC))
     V.:& FF.toFoldRecord (fracF wnh)
     V.:& FF.toFoldRecord (fracF wh)
     V.:& FF.toFoldRecord (fracF nwh)
     V.:& FF.toFoldRecord (fracF black)
     V.:& FF.toFoldRecord (fracF asian)
     V.:& FF.toFoldRecord (fracF other)
     V.:& FF.toFoldRecord (intRatio <$> FL.prefilter whiteGrad citF <*> FL.prefilter white citF)
     V.:& FF.toFoldRecord (citWgtdF (F.rgetField @DT.AvgIncome))
     V.:& FF.toFoldRecord (citWgtdF (F.rgetField @DT.PopPerSqMile))
     V.:& FF.toFoldRecord citF
     V.:& V.RNil

-- This is the thing to apply to loaded result data (with incumbents)
electionF :: forall ks.(Ord (F.Record ks)
                       , ks F.⊆ (ks V.++ '[BR.Candidate, ET.Party, ET.Votes, ET.Incumbent])
                       , F.ElemOf (ks V.++ '[BR.Candidate, ET.Party, ET.Votes, ET.Incumbent]) ET.Incumbent
                       , F.ElemOf (ks V.++ '[BR.Candidate, ET.Party, ET.Votes, ET.Incumbent]) ET.Party
                       , F.ElemOf (ks V.++ '[BR.Candidate, ET.Party, ET.Votes, ET.Incumbent]) ET.Votes
                       , F.ElemOf (ks V.++ '[BR.Candidate, ET.Party, ET.Votes, ET.Incumbent]) BR.Candidate
                       , FI.RecVec (ks V.++ ElectionR)
                       )
          => FL.FoldM (Either T.Text) (F.Record (ks V.++ [BR.Candidate, ET.Party, ET.Votes, ET.Incumbent])) (F.FrameRec (ks V.++ ElectionR))
electionF =
  FMR.concatFoldM $
    FMR.mapReduceFoldM
      (FMR.generalizeUnpack FMR.noUnpack)
      (FMR.generalizeAssign $ FMR.assignKeysAndData @ks)
      (FMR.makeRecsWithKeyM id $ FMR.ReduceFoldM $ const $ fmap (pure @[]) flattenVotesF)

data IncParty = None | Inc (ET.PartyT, Text) | Multi [Text]

updateIncParty :: IncParty -> (ET.PartyT, Text) -> IncParty
updateIncParty (Multi cs) (_, c) = Multi (c:cs)
updateIncParty (Inc (_, c)) (_, c') = Multi [c, c']
updateIncParty None (p, c) = Inc (p, c)

incPartyToInt :: IncParty -> Either T.Text Int
incPartyToInt None = Right 0
incPartyToInt (Inc (ET.Democratic, _)) = Right 1
incPartyToInt (Inc (ET.Republican, _)) = Right (negate 1)
incPartyToInt (Inc _) = Right 0
incPartyToInt (Multi cs) = Left $ "Error: Multiple incumbents: " <> T.intercalate "," cs

flattenVotesF :: FL.FoldM (Either T.Text) (F.Record [BR.Candidate, ET.Incumbent, ET.Party, ET.Votes]) (F.Record ElectionR)
flattenVotesF = FMR.postMapM (FL.foldM flattenF) aggregatePartiesF
  where
    party = F.rgetField @ET.Party
    votes = F.rgetField @ET.Votes
    incumbentPartyF =
      FMR.postMapM incPartyToInt $
        FL.generalize $
          FL.prefilter (F.rgetField @ET.Incumbent) $
            FL.premap (\r -> (F.rgetField @ET.Party r, F.rgetField @BR.Candidate r)) (FL.Fold updateIncParty None id)
    totalVotes =  FL.premap votes FL.sum
    demVotesF = FL.generalize $ FL.prefilter (\r -> party r == ET.Democratic) $ totalVotes
    repVotesF = FL.generalize $ FL.prefilter (\r -> party r == ET.Republican) $ totalVotes
    flattenF = (\ii dv rv tv -> ii F.&: dv F.&: rv F.&: tv F.&: V.RNil) <$> incumbentPartyF <*> demVotesF <*> repVotesF <*> FL.generalize totalVotes

aggregatePartiesF ::
  FL.FoldM
    (Either T.Text)
    (F.Record [BR.Candidate, ET.Incumbent, ET.Party, ET.Votes])
    (F.FrameRec [BR.Candidate, ET.Incumbent, ET.Party, ET.Votes])
aggregatePartiesF =
  let apF :: FL.FoldM (Either T.Text) (F.Record [ET.Party, ET.Votes]) (F.Record [ET.Party, ET.Votes])
      apF = FMR.postMapM ap (FL.generalize $ FL.premap (\r -> (F.rgetField @ET.Party r, F.rgetField @ET.Votes r)) FL.map)
        where
          ap pvs =
            let demvM = M.lookup ET.Democratic pvs
                repvM = M.lookup ET.Republican pvs
                votes = FL.fold FL.sum $ M.elems pvs
                partyE = case (demvM, repvM) of
                  (Nothing, Nothing) -> Right ET.Other
                  (Just _, Nothing) -> Right ET.Democratic
                  (Nothing, Just _) -> Right ET.Republican
                  (Just dv, Just rv) -> Left "Votes on both D and R lines"
             in fmap (\p -> p F.&: votes F.&: V.RNil) partyE
   in FMR.concatFoldM $
        FMR.mapReduceFoldM
          (FMR.generalizeUnpack FMR.noUnpack)
          (FMR.generalizeAssign $ FMR.assignKeysAndData @[BR.Candidate, ET.Incumbent] @[ET.Party, ET.Votes])
          (FMR.makeRecsWithKeyM id $ FMR.ReduceFoldM $ const $ fmap (pure @[]) apF)

-- TODO:  Use weights?  Design effect?
{-
countCCESVotesF :: FL.Fold (F.Record [CCES.Turnout, CCES.HouseVoteParty]) (F.Record [Surveyed, TVotes, DVotes])
countCCESVotesF =
  let surveyedF = FL.length
      votedF = FL.prefilter ((== CCES.T_Voted) . F.rgetField @CCES.Turnout) FL.length
      dVoteF = FL.prefilter ((== ET.Democratic) . F.rgetField @CCES.HouseVoteParty) votedF
  in (\s v d -> s F.&: v F.&: d F.&: V.RNil) <$> surveyedF <*> votedF <*> dVoteF

-- using cumulative
ccesMR :: (Foldable f, Monad m) => Int -> f (F.Record CCES.CCES_MRP) -> m (F.FrameRec CCESByCDR)
ccesMR earliestYear = BRF.frameCompactMRM
                     (FMR.unpackFilterOnField @BR.Year (>= earliestYear))
                     (FMR.assignKeysAndData @[BR.Year, BR.StateAbbreviation, BR.CongressionalDistrict, DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC])
                     countCCESVotesF


ccesCountedDemHouseVotesByCD :: (K.KnitEffects r, BR.CacheEffects r) => Bool -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec CCESByCDR))
ccesCountedDemHouseVotesByCD clearCaches = do
  cces_C <- CCES.ccesDataLoader
  let cacheKey = "model/house/ccesByCD.bin"
  when clearCaches $  BR.clearIfPresentD cacheKey
  BR.retrieveOrMakeFrame cacheKey cces_C $ \cces -> do
--    BR.logFrame cces
    ccesMR 2012 cces
-}

countCESVotesF :: FL.Fold
                  (F.Record [CCES.CatalistTurnoutC, CCES.MHouseVoteParty, CCES.MPresVoteParty])
                  (F.Record [Surveyed, Voted, HouseVotes, HouseDVotes, PresVotes, PresDVotes])
countCESVotesF =
  let houseVote (MT.MaybeData x) = maybe False (const True) x
      houseDVote (MT.MaybeData x) = maybe False (== ET.Democratic) x
      presVote (MT.MaybeData x) = maybe False (const True) x
      presDVote (MT.MaybeData x) = maybe False (== ET.Democratic) x
      surveyedF = FL.length
      votedF = FL.prefilter (CCES.catalistVoted . F.rgetField @CCES.CatalistTurnoutC) FL.length
      houseVotesF = FL.prefilter (houseVote . F.rgetField @CCES.MHouseVoteParty) votedF
      houseDVotesF = FL.prefilter (houseDVote . F.rgetField @CCES.MHouseVoteParty) votedF
      presVotesF = FL.prefilter (houseVote . F.rgetField @CCES.MPresVoteParty) votedF
      presDVotesF = FL.prefilter (houseDVote . F.rgetField @CCES.MPresVoteParty) votedF
  in (\s v hv hdv pv pdv -> s F.&: v F.&: hv F.&: hdv F.&: pv F.&: pdv F.&: V.RNil)
     <$> surveyedF <*> votedF <*> houseVotesF <*> houseDVotesF <*> presVotesF <*> presDVotesF

-- using each year's common content
cesMR :: (Foldable f, Monad m) => Int -> f (F.Record CCES.CESPR) -> m (F.FrameRec CCESByCDR)
cesMR earliestYear = BRF.frameCompactMRM
                     (FMR.unpackFilterOnField @BR.Year (>= earliestYear))
                     (FMR.assignKeysAndData @[BR.Year, BR.StateAbbreviation, BR.CongressionalDistrict, DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC])
                     countCESVotesF

cesCountedDemVotesByCD :: (K.KnitEffects r, BR.CacheEffects r) => Bool -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec CCESByCDR))
cesCountedDemVotesByCD clearCaches = do
  ces2020_C <- CCES.ces20Loader
  let cacheKey = "model/house/ces20ByCD.bin"
  when clearCaches $  BR.clearIfPresentD cacheKey
  BR.retrieveOrMakeFrame cacheKey ces2020_C $ \ces -> do
    cesMR 2020 ces

cpsCountedTurnoutByCD :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CPSVByCDR))
cpsCountedTurnoutByCD = do
  let afterYear y r = F.rgetField @BR.Year r >= y
      possible r = CPS.cpsPossibleVoter $ F.rgetField @ET.VotedYNC r
      citizen r = F.rgetField @DT.IsCitizen r
      includeRow r = afterYear 2012 r &&  possible r && citizen r
      voted r = CPS.cpsVoted $ F.rgetField @ET.VotedYNC r
      wgt r = {- F.rgetField @CPSVoterPUMSWeight r * -} F.rgetField @BR.CountyWeight r
      fld = BRCF.weightedCountFold @_ @(CPS.CPSVoterPUMS V.++ [BR.CongressionalDistrict, BR.CountyWeight])
            (\r -> F.rcast @CDKeyR r `V.rappend` CPS.cpsKeysToASER4H True (F.rcast r))
            (F.rcast  @[ET.VotedYNC, CPS.CPSVoterPUMSWeight, BR.CountyWeight])
            includeRow
            voted
            wgt
  cpsRaw_C <- CPS.cpsVoterPUMSWithCDLoader -- NB: this is only useful for CD rollup since counties may appear in multiple CDs.
  BR.retrieveOrMakeFrame "model/house/cpsVByCD.bin" cpsRaw_C $ return . FL.fold fld
{-
cpsCountedTurnoutByState :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CPSVByStateR))
cpsCountedTurnoutByState = do
  let afterYear y r = F.rgetField @BR.Year r >= y
      possible r = CPS.cpsPossibleVoter $ F.rgetField @ET.VotedYNC r
      citizen r = F.rgetField @DT.IsCitizen r
      includeRow r = afterYear 2012 r &&  possible r && citizen r
      voted r = CPS.cpsVoted $ F.rgetField @ET.VotedYNC r
      wgt r = F.rgetField @CPS.CPSVoterPUMSWeight r
      fld = BRCF.weightedCountFold @_ @CPS.CPSVoterPUMS
            (\r -> F.rcast @StateKeyR r `V.rappend` CPS.cpsKeysToASER4H True (F.rcast r))
            (F.rcast  @[ET.VotedYNC, CPS.CPSVoterPUMSWeight])
            includeRow
            voted
            wgt
  cpsRaw_C <- CPS.cpsVoterPUMSLoader -- NB: this is only useful for CD rollup since counties may appear in multiple CDs.
  BR.retrieveOrMakeFrame "model/house/cpsVByState.bin" cpsRaw_C $ return . FL.fold fld
-}
pumsReKey :: F.Record '[DT.Age5FC, DT.SexC, DT.CollegeGradC, DT.InCollege, DT.RaceAlone4C, DT.HispC]
          ->  F.Record '[DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.RaceAlone4C, DT.HispC]
pumsReKey r =
  let cg = F.rgetField @DT.CollegeGradC r
      ic = F.rgetField @DT.InCollege r
  in DT.age5FToSimple (F.rgetField @DT.Age5FC r)
     F.&: F.rgetField @DT.SexC r
     F.&: (if cg == DT.Grad || ic then DT.Grad else DT.NonGrad)
     F.&: F.rgetField @DT.RaceAlone4C r
     F.&: F.rgetField @DT.HispC r
     F.&: V.RNil

acsCopy2019to2020 :: F.FrameRec PUMSByCDR -> F.FrameRec PUMSByCDR
acsCopy2019to2020 rows = rows <> fmap changeYear2020 (F.filterFrame year2019 rows) where
  year2019 r = F.rgetField @BR.Year r == 2019
  changeYear2020 r = F.rputField @BR.Year 2020 r

type SenateRaceKeyR = [BR.Year, BR.StateAbbreviation, BR.Special, BR.Stage]

type ElexDataR = [ET.Office, BR.Stage, BR.Runoff, BR.Special, BR.Candidate, ET.Party, ET.Votes, ET.Incumbent]

type HouseModelCensusTablesByCD =
  Census.CensusTables Census.LDLocationR Census.ExtensiveDataR DT.Age5FC DT.SexC DT.CollegeGradC Census.RaceEthnicityC DT.IsCitizen Census.EmploymentC

type HouseModelCensusTablesByState =
  Census.CensusTables '[BR.StateFips] Census.ExtensiveDataR DT.Age5FC DT.SexC DT.CollegeGradC Census.RaceEthnicityC DT.IsCitizen Census.EmploymentC

pumsByCD :: (K.KnitEffects r, BR.CacheEffects r) => F.FrameRec PUMS.PUMS -> F.FrameRec BR.DatedCDFromPUMA2012 -> K.Sem r (F.FrameRec PUMSByCDR)
pumsByCD pums cdFromPUMA =  fmap F.rcast <$> PUMS.pumsCDRollup (earliest earliestYear) (pumsReKey . F.rcast) cdFromPUMA pums
  where
    earliestYear = 2016
    earliest year = (>= year) . F.rgetField @BR.Year

cachedPumsByCD :: forall r.(K.KnitEffects r, BR.CacheEffects r)
               => K.ActionWithCacheTime r (F.FrameRec PUMS.PUMS)
               -> K.ActionWithCacheTime r (F.FrameRec BR.DatedCDFromPUMA2012)
               -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec PUMSByCDR))
cachedPumsByCD pums_C cdFromPUMA_C = do
  let pumsByCDDeps = (,) <$> pums_C <*> cdFromPUMA_C
  fmap (fmap acsCopy2019to2020)
    $ BR.retrieveOrMakeFrame "model/house/pumsByCD.bin" pumsByCDDeps
    $ \(pums, cdFromPUMA) -> pumsByCD pums cdFromPUMA

prepCCESAndPums :: forall r.(K.KnitEffects r, BR.CacheEffects r) => Bool -> K.Sem r (K.ActionWithCacheTime r CCESAndPUMS)
prepCCESAndPums clearCache = do
  let earliestYear = 2016 -- set by ces for now
      earliest year = (>= year) . F.rgetField @BR.Year
  pums_C <- PUMS.pumsLoaderAdults
  cdFromPUMA_C <- BR.allCDFromPUMA2012Loader
  pumsByCD_C <- cachedPumsByCD pums_C cdFromPUMA_C
  countedCCES_C <- fmap (BR.fixAtLargeDistricts 0) <$> cesCountedDemVotesByCD clearCache
  cpsVByCD_C <- fmap (F.filterFrame $ earliest earliestYear) <$> cpsCountedTurnoutByCD
  K.ignoreCacheTime cpsVByCD_C >>= cpsDiagnostics "Pre Achen/Hur"
  -- first, do the turnout corrections
  stateTurnout_C <- BR.stateTurnoutLoader
  let achenHurDeps = (,,) <$> cpsVByCD_C <*> pumsByCD_C <*> stateTurnout_C
      achenHurCacheKey = "model/house/CPSV_AchenHur.bin"
  when clearCache $ BR.clearIfPresentD achenHurCacheKey
  cpsV_AchenHur_C <- BR.retrieveOrMakeFrame achenHurCacheKey achenHurDeps $ \(cpsV, acs, stateTurnout) -> do
    K.logLE K.Info "Doing Ghitza/Gelman logistic Achen/Hur adjustment to correct CPS for state-specific under-reporting."
    let ew r = FT.recordSingleton @ET.ElectoralWeight (F.rgetField @BRCF.WeightedSuccesses r / F.rgetField @BRCF.WeightedCount r)
        cpsWithProb = fmap (FT.mutate ew) cpsV
        (cpsWithProbAndCit, missing) = FJ.leftJoinWithMissing @(CDKeyR V.++ CPSPredictorR) cpsWithProb $ acs
    when (not $ null missing) $ K.knitError $ "Missing keys in cpsV/acs join: " <> show missing
    adjCPSProb <- FL.foldM (BRTA.adjTurnoutFold @PUMS.Citizens @ET.ElectoralWeight stateTurnout) cpsWithProbAndCit
    let adjVoters r = F.rputField @BRCF.WeightedSuccesses (F.rgetField @BRCF.WeightedCount r * F.rgetField @ET.ElectoralWeight r) r
    return $ fmap (F.rcast @CPSVByCDR . adjVoters) adjCPSProb
  K.ignoreCacheTime cpsV_AchenHur_C >>= cpsDiagnostics "Post Achen/Hur"
  let deps = (,,) <$> countedCCES_C <*> cpsV_AchenHur_C <*> pumsByCD_C
      cacheKey = "model/house/CCESAndPUMS.bin"
  when clearCache $ BR.clearIfPresentD cacheKey
  BR.retrieveOrMakeD cacheKey deps $ \(cces, cpsVByCD, pums) -> do
    -- get Density and avg income from PUMS and combine with election data for the district level data
    let fixDC_CD r = if (F.rgetField @BR.StateAbbreviation r == "DC")
                     then FT.fieldEndo @BR.CongressionalDistrict (const 1) r
                     else r
        pumsCDFixed = fmap fixDC_CD pums
        cpsVFixed = fmap fixDC_CD $ F.filterFrame (earliest earliestYear) cpsVByCD
        diInnerFold :: FL.Fold (F.Record [DT.PopPerSqMile, DT.AvgIncome, PUMS.Citizens, PUMS.NonCitizens]) (F.Record [PUMS.Citizens, DT.PopPerSqMile, DT.AvgIncome])
        diInnerFold =
          let cit = F.rgetField @PUMS.Citizens
              ppl r = cit r + F.rgetField @PUMS.NonCitizens r
              citF = FL.premap cit FL.sum
              citWeightedSumF f = (/) <$> FL.premap (\r -> realToFrac (cit r) * f r) FL.sum <*> fmap realToFrac citF
              pplF = FL.premap ppl FL.sum
              pplWeightedSumF f = (/) <$> FL.premap (\r -> realToFrac (ppl r) * f r) FL.sum <*> fmap realToFrac pplF
          in (\c d i -> c F.&: d F.&: i F.&: V.RNil) <$> citF <*> citWeightedSumF (F.rgetField @DT.PopPerSqMile) <*> citWeightedSumF (F.rgetField @DT.AvgIncome)
        diFold :: FL.Fold (F.Record PUMSByCDR) (F.FrameRec (CDKeyR V.++  [PUMS.Citizens, DT.PopPerSqMile, DT.AvgIncome]))
        diFold = FMR.concatFold
                 $ FMR.mapReduceFold
                 FMR.noUnpack
                 (FMR.assignKeysAndData @CDKeyR)
                 (FMR.foldAndAddKey diInnerFold)
        diByCD = FL.fold diFold pumsCDFixed

    return $ CCESAndPUMS cces cpsVFixed pumsCDFixed diByCD -- (F.toFrame $ fmap F.rcast $ cats)


race5FromCPS :: F.Record CPSVByCDR -> DT.Race5
race5FromCPS r =
  let race4A = F.rgetField @DT.RaceAlone4C r
      hisp = F.rgetField @DT.HispC r
  in DT.race5FromRaceAlone4AndHisp True race4A hisp

cpsDiagnostics :: K.KnitEffects r => Text -> F.FrameRec CPSVByCDR -> K.Sem r ()
cpsDiagnostics t cpsByCD = K.wrapPrefix "cpsDiagnostics" $ do
  let cpsCountsByYearFld = FMR.concatFold
                           $ FMR.mapReduceFold
                           FMR.noUnpack
                           (FMR.assignKeysAndData @'[BR.Year] @'[BRCF.Count, BRCF.WeightedCount])
                           (FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum)
  K.logLE K.Diagnostic t
  K.logLE K.Diagnostic "cps counts by year"
  BR.logFrame $ FL.fold cpsCountsByYearFld cpsByCD
  let isYear y r = F.rgetField @BR.Year r == y
      turnoutByRaceFld year mState =
        let stateFilter r = All $ maybe True (\s -> F.rgetField @BR.StateAbbreviation r == s) mState
            fltr r = getAll $ All (F.rgetField @BR.Year r == year) <> stateFilter r
        in FMR.concatFold
           $ FMR.mapReduceFold
           (FMR.unpackFilterRow fltr)
           (FMR.assign
             (FT.recordSingleton @DT.Race4C . DT.race4FromRace5 . race5FromCPS)
             (F.rcast @[BRCF.WeightedCount, BRCF.WeightedSuccesses]))
           (FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum)
  let (allCounts, nvCounts) = FL.fold ((,) <$> turnoutByRaceFld 2020 Nothing <*> turnoutByRaceFld 2020 (Just "NV")) cpsByCD
  K.logLE K.Diagnostic $ "All (county-weighted) by race: "
  BR.logFrame allCounts
  K.logLE K.Diagnostic $ "NV (county-weighted) by race: "
  BR.logFrame nvCounts


-- CCES diagnostics
type Voters = "Voters" F.:-> Double
type DemVoters = "DemVoters" F.:-> Double
type CCESBucketR = [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.Race5C, DT.HispC]

ccesDiagnostics :: (K.KnitEffects r, BR.CacheEffects r)
                => K.ActionWithCacheTime r CCESAndPUMS
                -> K.Sem r (K.ActionWithCacheTime r ((F.FrameRec [BR.Year,BR.StateAbbreviation, Voters, DemVoters, ET.DemShare]
                                                      , F.FrameRec [BR.Year,BR.StateAbbreviation, ET.CongressionalDistrict, Voters, DemVoters, ET.DemShare])))
ccesDiagnostics ccesAndPums_C = K.wrapPrefix "ccesDiagnostics" $ do
  K.logLE K.Info $ "computing CES diagnostics..."
  let pT r = (realToFrac $ F.rgetField @Voted r)/(realToFrac $ F.rgetField @Surveyed r)
      pD r = let hv = F.rgetField @HouseVotes r in if hv == 0 then 0 else (realToFrac $ F.rgetField @HouseDVotes r)/(realToFrac hv)
      cvap = realToFrac . F.rgetField @PUMS.Citizens
      addRace5 r = r F.<+> (FT.recordSingleton @DT.Race5C $ DT.race5FromRaceAlone4AndHisp True (F.rgetField @DT.RaceAlone4C r) (F.rgetField @DT.HispC r))
      compute rw rc = let voters = (pT rw * cvap rc) in (voters F.&: (pD rw * voters) F.&: V.RNil ) :: F.Record [Voters, DemVoters]
      psFld :: FL.Fold (F.Record [Voters, DemVoters]) (F.Record [Voters, DemVoters])
      psFld = FF.foldAllConstrained @Num FL.sum
      addShare r = let v = F.rgetField @Voters r in r F.<+> (FT.recordSingleton @ET.DemShare $ if v < 1 then 0 else F.rgetField @DemVoters r / v)
  states_C <- BR.retrieveOrMakeFrame "diagnostics/ccesPSByPumsStates.bin" ccesAndPums_C $ \ccesAndPums -> do
    let pumsFixed =  addRace5 <$> (F.filterFrame (\r -> F.rgetField @BR.Year r >= 2016) $ pumsRows ccesAndPums)
        (psByState, missing) = BRPS.joinAndPostStratify @'[BR.Year,BR.StateAbbreviation] @CCESBucketR @CCESVotingDataR @'[PUMS.Citizens]
                               compute
                               psFld
                               (F.rcast <$> ccesRows ccesAndPums)
                               (F.rcast <$> pumsFixed)
--    when (not $ null missing) $ K.knitError $ "ccesDiagnostics: Missing keys in cces/pums join: " <> show missing
    return $ addShare <$> psByState
  districts_C <- BR.retrieveOrMakeFrame "diagnostics/ccesPSByPumsCDs.bin" ccesAndPums_C $ \ccesAndPums -> do
    let pumsFixed =  addRace5 <$> (F.filterFrame (\r -> F.rgetField @BR.Year r >= 2016) $ pumsRows ccesAndPums)
        (psByCD, missing) = BRPS.joinAndPostStratify @'[BR.Year,BR.StateAbbreviation,ET.CongressionalDistrict] @CCESBucketR @CCESVotingDataR @'[PUMS.Citizens]
                               compute
                               psFld
                               (F.rcast <$> ccesRows ccesAndPums)
                               (F.rcast <$> pumsFixed)
--    when (not $ null missing) $ K.knitError $ "ccesDiagnostics: Missing keys in cces/pums join: " <> show missing
    return $ addShare <$> psByCD
--  K.ignoreCacheTime states_C >>= BR.logFrame
  return $ (,) <$> states_C <*> districts_C





--
groupBuilder :: forall rs ks.
                ( F.ElemOf rs BR.StateAbbreviation
                , F.ElemOf rs DT.CollegeGradC
                , F.ElemOf rs DT.SexC
                , F.ElemOf rs DT.Race5C
                , F.ElemOf rs DT.HispC
                , ks F.⊆ rs
                , Show (F.Record ks)
                , Typeable rs
                , Typeable ks
                , Ord (F.Record ks))
             => SB.GroupTypeTag (F.Record ks)
             -> [Text]
             -> [Text]
             -> [F.Record ks]
             -> SB.StanGroupBuilderM (CCESAndPUMS, F.FrameRec rs) ()
groupBuilder psGroup districts states psKeys = do
  voterData <- SB.addDataSetToGroupBuilder SB.ModelUse "VoteData" (SB.ToFoldable $ ccesRows . fst)
  SB.addGroupIndexForDataSet cdGroup voterData $ SB.makeIndexFromFoldable show districtKey districts
  SB.addGroupIndexForDataSet stateGroup voterData $ SB.makeIndexFromFoldable show (F.rgetField @BR.StateAbbreviation) states
  SB.addGroupIndexForDataSet sexGroup voterData $ SB.makeIndexFromEnum (F.rgetField @DT.SexC)
  SB.addGroupIndexForDataSet educationGroup voterData $ SB.makeIndexFromEnum (F.rgetField @DT.CollegeGradC)
  SB.addGroupIndexForDataSet raceGroup voterData $ SB.makeIndexFromEnum mergeRace5AndHispanic
  SB.addGroupIndexForDataSet hispanicGroup voterData $ SB.makeIndexFromEnum (F.rgetField @DT.HispC)
  cdData <- SB.addDataSetToGroupBuilder SB.ModelUse "CDData" (SB.ToFoldable $ districtRows . fst)
  SB.addGroupIndexForCrosswalk cdData $ SB.makeIndexFromFoldable show districtKey districts
  psData <- SB.addDataSetToGroupBuilder SB.GQOnlyUse "DistrictPS" (SB.ToFoldable snd)
  SB.addGroupIndexForDataSet stateGroup psData $ SB.makeIndexFromFoldable show (F.rgetField @BR.StateAbbreviation) states
  SB.addGroupIndexForDataSet educationGroup psData $ SB.makeIndexFromEnum (F.rgetField @DT.CollegeGradC)
  SB.addGroupIndexForDataSet sexGroup psData $ SB.makeIndexFromEnum (F.rgetField @DT.SexC)
  SB.addGroupIndexForDataSet raceGroup psData $ SB.makeIndexFromEnum (F.rgetField @DT.Race5C)
  SB.addGroupIndexForDataSet psGroup psData $ SB.makeIndexFromFoldable show F.rcast psKeys
  return ()


data GroupModel = BaseG
                 | PlusStateG
                 | PlusSexEduG
                 | PlusRaceEduG
                 | PlusInteractionsG
                 | PlusStateAndStateRaceG
                 | PlusStateAndStateInteractionsG
                 deriving (Show, Eq, Ord, Generic)

instance Flat.Flat GroupModel
type instance FI.VectorFor GroupModel = Vector.Vector

data DensityModel = BaseD
                  | PlusEduD
                  | PlusRaceD
                  | PlusHRaceD
                  | PlusInteractionsD
                  | PlusNCHRaceD
                  | PlusHStateD
                  deriving (Show, Eq, Ord, Generic)

instance Flat.Flat DensityModel
type instance FI.VectorFor DensityModel = Vector.Vector

data VoteSource = HouseVS | PresVS | CompositeVS deriving (Show, Eq, Ord, Generic)
instance Flat.Flat VoteSource
type instance FI.VectorFor VoteSource = Vector.Vector
printVoteSource :: VoteSource -> Text
printVoteSource HouseVS = "HouseVotes"
printVoteSource PresVS = "PresVotes"
printVoteSource CompositeVS = "CompositeVotes"


getVotes :: VoteSource -> (F.Record CCESByCDR -> Int, F.Record CCESByCDR -> Int)
getVotes HouseVS = (F.rgetField @HouseVotes, F.rgetField @HouseDVotes)
getVotes PresVS = (F.rgetField @PresVotes, F.rgetField @PresDVotes)
getVotes CompositeVS =
  let hv = F.rgetField @HouseVotes
      hdv = F.rgetField @HouseVotes
      pv = F.rgetField @PresVotes
      pdv = F.rgetField @PresDVotes
      f h p r = round (realToFrac ((hv r * h r) + (pv r * p r))/realToFrac (hv r + pv r))
  in (f hv pv, f hdv pdv)

data Model = Model { voteSource :: VoteSource
                   , groupModel :: GroupModel
                   , densityModel :: DensityModel
                   }  deriving (Show, Eq, Ord, Generic)

instance Flat.Flat Model
type instance FI.VectorFor Model = Vector.Vector

modelLabel :: Model -> Text
modelLabel (Model vs gm dm) = printVoteSource vs <> "_" <> show gm <> "_" <> show dm


electionModel :: forall rs ks r.
                 (K.KnitEffects r
                 , BR.CacheEffects r
                 , F.ElemOf rs BR.StateAbbreviation
                 , F.ElemOf rs DT.CollegeGradC
                 , F.ElemOf rs DT.SexC
                 , F.ElemOf rs DT.Race5C
                 , F.ElemOf rs DT.HispC
                 , F.ElemOf rs DT.PopPerSqMile
                 , F.ElemOf rs Census.Count
                 ,  (ks V.++ '[MT.ModelId Model, ModeledShare]) F.⊆  (BR.Year : MT.ModelId Model : (ks V.++ '[ModeledShare]))
                 , FI.RecVec (ks V.++ '[ModeledShare])
                 , FI.RecVec  (ks V.++ '[MT.ModelId Model, ModeledShare])
                 , ks F.⊆ rs
                 , V.RMap (ks V.++ '[MT.ModelId Model, ModeledShare])
                 , Show (F.Record ks)
                 , Typeable rs
                 , Typeable ks
                 , Ord (F.Record ks)
                 , Flat.GFlatDecode
                          (Flat.Rep
                             (F.Rec FS.SElField (ks V.++ '[MT.ModelId Model, ModeledShare])))
                 , Flat.GFlatEncode
                          (Flat.Rep
                             (F.Rec FS.SElField (ks V.++ '[MT.ModelId Model, ModeledShare])))
                 , Flat.GFlatSize
                          (Flat.Rep
                             (F.Rec FS.SElField (ks V.++ '[MT.ModelId Model, ModeledShare])))
                 , Generic
                   (F.Rec FS.SElField (ks V.++ '[MT.ModelId Model, ModeledShare]))
                 )
              => Bool
              -> Bool
              -> BR.StanParallel
              -> Text
              -> Model
              -> Int
              -> (SB.GroupTypeTag (F.Record ks), Text, SB.GroupSet)
              -> K.ActionWithCacheTime r CCESAndPUMS
              -> K.ActionWithCacheTime r (F.FrameRec rs)
              -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec (ModelResultsR ks)))
electionModel clearCaches parallel stanParallelCfg modelDir model datYear (psGroup, psDataSetName, psGroupSet) dat_C psDat_C = K.wrapPrefix "stateLegModel" $ do
  K.logLE K.Info $ "(Re-)running turnout/pref model if necessary."
  let jsonDataName = psDataSetName <> "_" <> modelLabel model <> "_" <> show datYear <> if parallel then "_P" else ""  -- because of grainsize
      dataAndCodeBuilder :: MRP.BuilderM (CCESAndPUMS, F.FrameRec rs) ()
      dataAndCodeBuilder = do
        -- data
        voteData <- SB.dataSetTag @(F.Record CCESByCDR) "VoteData"
        cdData <- SB.dataSetTag @(F.Record DistrictDemDataR) "CDData"
        SB.addDataSetsCrosswalk voteData cdData cdGroup
        SB.setDataSetForBindings voteData
        pplWgtsCD <- SB.addCountData cdData "Citizens" (F.rgetField @PUMS.Citizens)

        (feMatrices, centerF) <- SFE.addFixedEffectsData cdData  densityRowFromData (Just pplWgtsCD)--(SFE.FixedEffects 1 densityPredictor)
        (feColDim, _, colIndexKey) <- SFE.colDimAndDimKeys feMatrices

        let normal x = SB.normal Nothing $ SB.scalar $ show x
            binaryPrior = normal 2
            sigmaPrior = normal 2
            fePrior = normal 2

        let simpleGroupModel x = SB.NonHierarchical SB.STZNone (normal x)
            muV gtt s = SB.StanVar ("mu" <> s <> "_" <> SB.taggedGroupName gtt) SB.StanReal
            sigmaV gtt s = SB.StanVar ("sigma" <> s <> "_" <> SB.taggedGroupName gtt) SB.StanReal
            hierHPs gtt s = M.fromList
              [
                (muV gtt s, ("", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
              , (sigmaV gtt s, ("<lower=0>", \v -> SB.var v `SB.vectorSample` (SB.normal (Just $ SB.scalar "0") (SB.scalar "2"))))
              ]
            hierGroupModel gtt s = SB.Hierarchical SB.STZNone (hierHPs gtt s) (SB.Centered $ SB.normal (Just $ SB.var $ muV gtt s) (SB.var $ sigmaV gtt s))
            ncGMCenterF gtt s bv@(SB.StanVar sn st) brv = do
              bv' <- SB.stanDeclare sn st ""
              SB.addExprLine ("nonCentered for " <> SB.taggedGroupName gtt)
                $ SB.vectorizedOne (SB.taggedGroupName gtt) (SB.var bv' `SB.eq` (SB.var (muV gtt s) `SB.plus`  (SB.var (sigmaV gtt s) `SB.times`  SB.var brv)))
            hierGroupModelNC gtt s = SB.Hierarchical SB.STZNone (hierHPs gtt s) (SB.NonCentered SB.stdNormal (ncGMCenterF gtt s))
            gmSigmaName gtt suffix = "sigma" <> suffix <> "_" <> SB.taggedGroupName gtt
            groupModelMR gtt s = SB.hierarchicalCenteredFixedMeanNormal 0 (gmSigmaName gtt s) sigmaPrior SB.STZNone
        -- Turnout
        cvap <- SB.addCountData voteData "CVAP" (F.rgetField @Surveyed)
        votes <- SB.addCountData voteData "VOTED" (F.rgetField @Voted)

        (gSexT, sexTV) <- MRP.addGroup voteData binaryPrior (simpleGroupModel 1) sexGroup (Just "T")
        (gEduT, eduTV) <- MRP.addGroup voteData binaryPrior (simpleGroupModel 1) educationGroup (Just "T")
        (gRaceT, raceTV) <- MRP.addGroup voteData binaryPrior (hierGroupModel raceGroup "T") raceGroup (Just "T")
--        gStateT <- MRP.addGroup voteData binaryPrior (hierGroupModel stateGroup) stateGroup (Just "T")
        let distT = SB.binomialLogitDist cvap

        -- Preference
        let (votesF, dVotesF) = getVotes $ voteSource model
        hVotes <- SB.addCountData voteData "VOTES_C" votesF --(F.rgetField @HouseVotes)
        dVotes <- SB.addCountData voteData "DVOTES_C" dVotesF --(F.rgetField @HouseDVotes)
        (gSexP, sexPV) <- MRP.addGroup voteData binaryPrior (simpleGroupModel 1) sexGroup (Just "P")
        (gEduP, eduPV) <- MRP.addGroup voteData binaryPrior (simpleGroupModel 1) educationGroup (Just "P")
        (gRaceP, racePV) <- MRP.addGroup voteData binaryPrior (hierGroupModel raceGroup "P") raceGroup (Just "P")
        let distP = SB.binomialLogitDist hVotes

        (thetaTMultF, betaTMultF, thetaPMultF, betaPMultF) <- case densityModel model of
          BaseD -> do
            let baseFEM = (SFE.NonInteractingFE True fePrior)
            (thetaTMultF', betaTMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "T")
            (thetaPMultF', betaPMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "P")
            return (thetaTMultF', betaTMultF', thetaPMultF', betaPMultF')
          PlusEduD -> do
            let baseFEM = (SFE.NonInteractingFE True fePrior)
            (thetaTMultF', betaTMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "T")
            (thetaPMultF', betaPMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "P")
            let eduDensityGM = SB.BinarySymmetric fePrior
                eduDensityFEM = SFE.InteractingFE True educationGroup eduDensityGM
            (thetaEduTMultF, betaEduTMultF) <- SFE.addFixedEffectsParametersAndPriors eduDensityFEM feMatrices cdData voteData (Just "T")
            (thetaEduPMultF, betaEduPMultF) <- SFE.addFixedEffectsParametersAndPriors eduDensityFEM feMatrices cdData voteData (Just "P")
            let tTMultF' ik x = SB.plus <$> thetaTMultF' ik x <*> thetaEduTMultF ik x
                tPMultF' ik x = SB.plus <$> thetaPMultF' ik x <*> thetaEduPMultF ik x
                bTMultF' ik x = SB.plus <$> betaTMultF' ik x <*> betaEduTMultF ik x
                bPMultF' ik x = SB.plus <$> betaPMultF' ik x <*> betaEduPMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')
          PlusRaceD -> do
            let baseFEM = (SFE.NonInteractingFE True fePrior)
            (thetaTMultF', betaTMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "T")
            (thetaPMultF', betaPMultF') <- SFE.addFixedEffectsParametersAndPriors baseFEM feMatrices cdData voteData (Just "P")
            let raceDensityGM = SB.NonHierarchical SB.STZNone fePrior
                raceDensityFEM = SFE.InteractingFE True raceGroup raceDensityGM
            (thetaRaceTMultF, betaRaceTMultF) <- SFE.addFixedEffectsParametersAndPriors raceDensityFEM feMatrices cdData voteData (Just "T")
            (thetaRacePMultF, betaRacePMultF) <- SFE.addFixedEffectsParametersAndPriors raceDensityFEM feMatrices cdData voteData (Just "P")
            let tTMultF' ik x = SB.plus <$> thetaTMultF' ik x <*> thetaRaceTMultF ik x
                tPMultF' ik x = SB.plus <$> thetaPMultF' ik x <*> thetaRacePMultF ik x
                bTMultF' ik x = SB.plus <$> betaTMultF' ik x <*> betaRaceTMultF ik x
                bPMultF' ik x = SB.plus <$> betaPMultF' ik x <*> betaRacePMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')
          PlusHRaceD -> do
            let muV s = SB.StanVar ("muRaceDensity" <> s) SB.StanReal
                sigmaV s = SB.StanVar ("sigmaRaceDensity" <> s) SB.StanReal
                hyperParameters s = M.fromList
                  [
                  (muV s, ("", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  , (sigmaV s, ("<lower=0>", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  ]
                cPrior s = SB.normal (Just $ SB.var $ muV s) (SB.var $ sigmaV s)
                raceDensityGM s = SB.Hierarchical SB.STZNone (hyperParameters s) (SB.Centered $ cPrior s)
                raceDensityFEM s = SFE.InteractingFE True raceGroup (raceDensityGM s)
            (thetaRaceTMultF, betaRaceTMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "T") feMatrices cdData voteData (Just "T")
            (thetaRacePMultF, betaRacePMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "P") feMatrices cdData voteData (Just "P")
            let tTMultF' ik x = thetaRaceTMultF ik x
                tPMultF' ik x = thetaRacePMultF ik x
                bTMultF' ik x = betaRaceTMultF ik x
                bPMultF' ik x = betaRacePMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')
          PlusInteractionsD -> do
            let muV s = SB.StanVar ("muRaceDensity" <> s) SB.StanReal
                sigmaV s = SB.StanVar ("sigmaRaceDensity" <> s) SB.StanReal
                hyperParameters s = M.fromList
                  [
                  (muV s, ("", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  , (sigmaV s, ("<lower=0>", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  ]
                cPrior s = SB.normal (Just $ SB.var $ muV s) (SB.var $ sigmaV s)
                raceDensityGM s = SB.Hierarchical SB.STZNone (hyperParameters s) (SB.Centered $ cPrior s)
                raceDensityFEM s = SFE.InteractingFE True raceGroup (raceDensityGM s)
            (thetaRaceTMultF, betaRaceTMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "T") feMatrices cdData voteData (Just "T")
            (thetaRacePMultF, betaRacePMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "P") feMatrices cdData voteData (Just "P")
            let eduDensityGM = SB.BinarySymmetric fePrior
                eduDensityFEM = SFE.InteractingFE True educationGroup eduDensityGM
            (thetaEduTMultF, betaEduTMultF) <- SFE.addFixedEffectsParametersAndPriors eduDensityFEM feMatrices cdData voteData (Just "T")
            (thetaEduPMultF, betaEduPMultF) <- SFE.addFixedEffectsParametersAndPriors eduDensityFEM feMatrices cdData voteData (Just "P")
            let sexDensityGM = SB.BinarySymmetric fePrior
                sexDensityFEM = SFE.InteractingFE True sexGroup sexDensityGM
            (thetaSexTMultF, betaSexTMultF) <- SFE.addFixedEffectsParametersAndPriors sexDensityFEM feMatrices cdData voteData (Just "T")
            (thetaSexPMultF, betaSexPMultF) <- SFE.addFixedEffectsParametersAndPriors sexDensityFEM feMatrices cdData voteData (Just "P")
            let add3 x y z = SB.multiOp "+" (x :| [y,z])
                tTMultF' ik x = add3 <$> thetaRaceTMultF ik x <*> thetaEduTMultF ik x <*> thetaSexTMultF ik x
                tPMultF' ik x = add3 <$> thetaRacePMultF ik x <*> thetaEduPMultF ik x <*> thetaSexPMultF ik x
                bTMultF' ik x = add3 <$> betaRaceTMultF ik x <*> betaEduTMultF ik x <*> betaSexTMultF ik x
                bPMultF' ik x = add3 <$> betaRacePMultF ik x <*> betaEduPMultF ik x <*> betaSexPMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')
          PlusNCHRaceD -> do
            let muV s = SB.StanVar ("muRaceDensity" <> s) (SB.StanVector feColDim)
                sigmaV s = SB.StanVar ("sigmaRaceDensity" <> s) (SB.StanVector feColDim)
                hyperParameters s = M.fromList
                  [
                  (muV s, ("", \v -> SB.vectorizedOne colIndexKey (SB.var v) `SB.vectorSample` SB.stdNormal))
                  , (sigmaV s, ("<lower=0>", \v -> SB.vectorizedOne colIndexKey (SB.var v) `SB.vectorSample` SB.stdNormal))
                  ]
                rawPrior = SB.stdNormal --SB.normal (Just $ SB.name $ mu s) (SB.name $ sigma s)
                centerF s bv@(SB.StanVar sn st) brv = do
                  bv' <- SB.stanDeclare sn st ""
                  SB.stanForLoopB "k" Nothing colIndexKey
                    $ SB.stanForLoopB "g" Nothing "Race"
                    $ SB.addExprLine "PlusNCHRaceD"
                    $ SB.var bv' `SB.eq` (SB.var (muV s) `SB.plus`  (SB.var (sigmaV s) `SB.times`  SB.var brv))
                raceDensityGM s = SB.Hierarchical SB.STZNone (hyperParameters s) (SB.NonCentered rawPrior (centerF s))
                raceDensityFEM s = SFE.InteractingFE True raceGroup (raceDensityGM s)
            (thetaRaceTMultF, betaRaceTMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "T") feMatrices cdData voteData (Just "T")
            (thetaRacePMultF, betaRacePMultF) <- SFE.addFixedEffectsParametersAndPriors (raceDensityFEM "P") feMatrices cdData voteData (Just "P")
            let tTMultF' ik x = thetaRaceTMultF ik x
                tPMultF' ik x = thetaRacePMultF ik x
                bTMultF' ik x = betaRaceTMultF ik x
                bPMultF' ik x = betaRacePMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')
          PlusHStateD -> do
            let mu s = "muStateDensity" <> s
                sigma s = "sigmaStateDensity" <> s
                hyperParameters s = M.fromList
                  [
                  (SB.StanVar (mu s) SB.StanReal, ("", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  , (SB.StanVar (sigma s) SB.StanReal, ("<lower=0>", \v -> SB.var v `SB.vectorSample` SB.stdNormal))
                  ]
                cPrior s = SB.normal (Just $ SB.name $ mu s) (SB.name $ sigma s)
                stateDensityGM s = SB.Hierarchical SB.STZNone (hyperParameters s) (SB.Centered $ cPrior s)
                stateDensityFEM s = SFE.InteractingFE True stateGroup (stateDensityGM s)
            (thetaStateTMultF, betaStateTMultF) <- SFE.addFixedEffectsParametersAndPriors (stateDensityFEM "T") feMatrices cdData voteData (Just "T")
            (thetaStatePMultF, betaStatePMultF) <- SFE.addFixedEffectsParametersAndPriors (stateDensityFEM "P") feMatrices cdData voteData (Just "P")
            let tTMultF' ik x = thetaStateTMultF ik x
                tPMultF' ik x = thetaStatePMultF ik x
                bTMultF' ik x = betaStateTMultF ik x
                bPMultF' ik x = betaStatePMultF ik x
            return (tTMultF', bTMultF', tPMultF', bPMultF')

        (q', feCDT, feCDP) <- SB.inBlock SB.SBModel $ SB.useDataSetForBindings voteData $ do
          q <- SB.stanBuildEither $ SFE.qrM SFE.qM feMatrices
          reIndexedQ <- SFE.reIndex (SB.dataSetName cdData) (SB.crosswalkIndexKey cdData) q
          feCDT' <- thetaTMultF (SB.dataSetName voteData) reIndexedQ
          feCDP' <- thetaPMultF (SB.dataSetName voteData) reIndexedQ
          return (reIndexedQ, feCDT', feCDP')
--        SB.stanBuildError $ "Q'="  <> show q'

        (logitT_sample, logitT_ps, logitP_sample, logitP_ps) <- case groupModel model of
              BaseG -> return (\d -> SB.multiOp "+" $ d :| [gRaceT, gSexT, gEduT]
                             ,\d -> SB.multiOp "+" $ d :| [gRaceT, gSexT, gEduT]
                             ,\d -> SB.multiOp "+" $ d :| [gRaceP, gSexP, gEduP]
                             ,\d -> SB.multiOp "+" $ d :| [gRaceP, gSexP, gEduP]
                             )
              PlusStateG -> do
                (gStateT, stateTV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "T") stateGroup (Just "T")
                (gStateP, statePV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "P") stateGroup (Just "P")
                let logitT d = SB.multiOp "+" $ d :| [gRaceT, gSexT, gEduT, gStateT]
                    logitP d = SB.multiOp "+" $ d :| [gRaceP, gSexP, gEduP, gStateP]
                return (logitT, logitT, logitP, logitP)
              PlusSexEduG -> do
                let hierGM s = SB.hierarchicalCenteredFixedMeanNormal 0 ("sigmaSexEdu" <> s) sigmaPrior SB.STZNone
                sexEduT <- MRP.addInteractions2 voteData (hierGM "T") sexGroup educationGroup (Just "T")
                vSexEduT <- SB.inBlock SB.SBModel $ SB.vectorizeVar sexEduT (SB.dataSetName voteData)
                sexEduP <- MRP.addInteractions2 voteData (hierGM "P") sexGroup educationGroup (Just "P")
                vSexEduP <- SB.inBlock SB.SBModel $ SB.vectorizeVar sexEduP (SB.dataSetName voteData)
                let logitT_sample d = SB.multiOp "+" $ d :| [gRaceT, gSexT, gEduT, SB.var vSexEduT]
                    logitT_ps d = SB.multiOp "+" $ d :| [gRaceT, gSexT, gEduT, SB.var sexEduT]
                    logitP_sample d = SB.multiOp "+" $ d :| [gRaceP, gSexP, gEduP, SB.var vSexEduP]
                    logitP_ps d = SB.multiOp "+" $ d :| [gRaceP, gSexP, gEduP, SB.var sexEduP]
                return (logitT_sample, logitT_ps, logitP_sample, logitP_ps)
              PlusRaceEduG -> do
                let groups = MRP.addGroupForInteractions raceGroup
                             $ MRP.addGroupForInteractions educationGroup mempty
                let hierGM s = SB.hierarchicalCenteredFixedMeanNormal 0 ("sigmaRaceEdu" <> s) sigmaPrior SB.STZNone
                raceEduT <- MRP.addInteractions voteData (hierGM "T") groups 2 (Just "T")
                vRaceEduT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) raceEduT
                raceEduP <- MRP.addInteractions voteData (hierGM "P") groups 2 (Just "P")
                vRaceEduP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) raceEduP
                let logitT_sample d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT] ++ fmap SB.var vRaceEduT)
                    logitT_ps d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT] ++ fmap SB.var raceEduT)
                    logitP_sample d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP] ++ fmap SB.var vRaceEduP)
                    logitP_ps d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP] ++ fmap SB.var raceEduP)
                return (logitT_sample, logitT_ps, logitP_sample, logitP_ps)
              PlusInteractionsG -> do
                let groups = MRP.addGroupForInteractions raceGroup
                             $ MRP.addGroupForInteractions sexGroup
                             $ MRP.addGroupForInteractions educationGroup mempty
                let hierGM s = SB.hierarchicalCenteredFixedMeanNormal 0 ("sigmaRaceSexEdu" <> s) sigmaPrior SB.STZNone
                interT <- MRP.addInteractions voteData (hierGM "T") groups 2 (Just "T")
                vInterT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) interT
                interP <- MRP.addInteractions voteData (hierGM "P") groups 2 (Just "P")
                vInterP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) interP
                let logitT_sample d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT] ++ fmap SB.var vInterT)
                    logitT_ps d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT] ++ fmap SB.var interT)
                    logitP_sample d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP] ++ fmap SB.var vInterP)
                    logitP_ps d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP] ++ fmap SB.var interP)
                return (logitT_sample, logitT_ps, logitP_sample, logitP_ps)
              PlusStateAndStateRaceG -> do
                (gStateT, stateTV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "T") stateGroup (Just "T")
                (gStateP, statePV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "P") stateGroup (Just "P")
                let groups = MRP.addGroupForInteractions stateGroup
                             $ MRP.addGroupForInteractions raceGroup mempty
                let hierGM s = SB.hierarchicalCenteredFixedMeanNormal 0 ("sigmaStateRaceEdu" <> s) sigmaPrior SB.STZNone
                interT <- MRP.addInteractions voteData (hierGM "T") groups 2 (Just "T")
                vInterT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) interT
                interP <- MRP.addInteractions voteData (hierGM "P") groups 2 (Just "P")
                vInterP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) interP
                let logitT_sample d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT, gStateT] ++ fmap SB.var vInterT)
                    logitT_ps d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT, gStateT] ++ fmap SB.var interT)
                    logitP_sample d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP, gStateP] ++ fmap SB.var vInterP)
                    logitP_ps d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP, gStateP] ++ fmap SB.var interP)
                return (logitT_sample, logitT_ps, logitP_sample, logitP_ps)
              PlusStateAndStateInteractionsG -> do
                (gStateT, stateTV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "T") stateGroup (Just "T")
                (gStateP, statePV) <- MRP.addGroup voteData binaryPrior (groupModelMR stateGroup "P") stateGroup (Just "P")
                let iGroupRace = MRP.addGroupForInteractions stateGroup
                                 $ MRP.addGroupForInteractions raceGroup mempty
                    iGroupSex = MRP.addGroupForInteractions stateGroup
                                $ MRP.addGroupForInteractions sexGroup mempty
                    iGroupEdu = MRP.addGroupForInteractions stateGroup
                                $ MRP.addGroupForInteractions educationGroup mempty
                let hierGM s = SB.hierarchicalCenteredFixedMeanNormal 0 ("sigmaStateRaceEdu" <> s) sigmaPrior SB.STZNone
                stateRaceT <- MRP.addInteractions voteData (hierGM "T") iGroupRace 2 (Just "T")
                vStateRaceT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateRaceT
                stateRaceP <- MRP.addInteractions voteData (hierGM "P") iGroupRace 2 (Just "P")
                vStateRaceP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateRaceP
                stateSexT <- MRP.addInteractions voteData (hierGM "T") iGroupSex 2 (Just "T")
                vStateSexT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateSexT
                stateSexP <- MRP.addInteractions voteData (hierGM "P") iGroupSex 2 (Just "P")
                vStateSexP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateSexP
                stateEduT <- MRP.addInteractions voteData (hierGM "T") iGroupEdu 2 (Just "T")
                vStateEduT <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateEduT
                stateEduP <- MRP.addInteractions voteData (hierGM "P") iGroupEdu 2 (Just "P")
                vStateEduP <- traverse (\x -> SB.inBlock SB.SBModel $ SB.vectorizeVar x (SB.dataSetName voteData)) stateEduP
                let logitT_sample d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT, gStateT]
                                                              ++ fmap SB.var vStateRaceT
                                                              ++ fmap SB.var vStateSexT
                                                              ++ fmap SB.var vStateEduT
                                                            )
                    logitT_ps d = SB.multiOp "+" $ d :| ([gRaceT, gSexT, gEduT, gStateT]
                                                          ++ fmap SB.var stateRaceT
                                                          ++ fmap SB.var stateSexT
                                                          ++ fmap SB.var stateEduT
                                                        )
                    logitP_sample d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP, gStateP]
                                                              ++ fmap SB.var vStateRaceP
                                                              ++ fmap SB.var vStateSexP
                                                              ++ fmap SB.var vStateEduP
                                                            )
                    logitP_ps d = SB.multiOp "+" $ d :| ([gRaceP, gSexP, gEduP, gStateP]
                                                          ++ fmap SB.var stateRaceP
                                                          ++ fmap SB.var stateSexP
                                                          ++ fmap SB.var stateEduP
                                                        )
                return (logitT_sample, logitT_ps, logitP_sample, logitP_ps)

        let serialSample = do
              SB.sampleDistV voteData distT (logitT_sample feCDT) votes
              SB.sampleDistV voteData distP (logitP_sample feCDP) dVotes
            parallelSample = do
              SB.parallelSampleDistV "turnout" voteData distT (logitT_sample feCDT) votes
              SB.parallelSampleDistV "preference" voteData distP (logitP_sample feCDP) dVotes

        if parallel then parallelSample else serialSample

        psData <- SB.dataSetTag @(F.Record rs) "DistrictPS"

--        SB.addUseBindingToDataSet psData
--        SB.stanBuildError $ "mv=" <> show mv
--        (densityTV, densityPV) <- SB.inBlock SB.SBGeneratedQuantities $ SB.useDataSetForBindings psData $ do

        let psPreCompute = do
              mv <- SB.add2dMatrixData psData densityRowFromData (Just 0) Nothing --(Vector.singleton . getDensity)
              cmVar <- centerF mv
              densityTV' <- betaTMultF (SB.dataSetName psData) cmVar --SB.matMult cmVar betaTVar
              densityPV' <- betaPMultF (SB.dataSetName psData) cmVar -- SB.matMult cmVar betaPVar
              return (densityTV', densityPV')

            psExprF (densityTV, densityPV) = do
              pT <- SB.stanDeclareRHS "pT" SB.StanReal "" $ SB.familyExp distT $ logitT_ps densityTV
              pD <- SB.stanDeclareRHS "pD" SB.StanReal "" $ SB.familyExp distP $ logitP_ps densityPV
              --return $ SB.var pT `SB.times` SB.paren ((SB.scalar "2" `SB.times` SB.var pD) `SB.minus` SB.scalar "1")
              return $ SB.var pT `SB.times` SB.var pD
--            pTExprF ik = SB.stanDeclareRHS "pT" SB.StanReal "" $ SB.familyExp distT ik $ logitT_ps densityTE
--            pDExprF ik = SB.stanDeclareRHS "pD" SB.StanReal "" $ SB.familyExp distP ik $ logitP_ps densityPE

        let postStrat =
              MRP.addPostStratification @(CCESAndPUMS, F.FrameRec rs)
              (psPreCompute, psExprF)
              Nothing
              voteData
              psData
              psGroupSet
              (realToFrac . F.rgetField @Census.Count)
              (MRP.PSShare $ Just $ SB.name "pT")
              (Just psGroup)
        postStrat

{-
  -- raw probabilities
        SB.inBlock SB.SBGeneratedQuantities $ do
          let pArrayDims =
                [ SB.NamedDim $ SB.taggedGroupName sexGroup,
                  SB.NamedDim $ SB.taggedGroupName educationGroup,
                  SB.NamedDim $ SB.taggedGroupName raceGroup
                ]
              pTRHS = SB.familyExp distT "" $ logitT_ps densityTE
              pDRHS = SB.familyExp distT "" $ logitP_ps densityPE
          pTVar <- SB.stanDeclare "probT" (SB.StanArray pArrayDims SB.StanReal) "<lower=0, upper=1>"
          pDVar <- SB.stanDeclare "probD" (SB.StanArray pArrayDims SB.StanReal) "<lower=0, upper=1>"
          SB.useDataSetForBindings sldData $ do
            SB.stanForLoopB "n" Nothing "SLD_Demographics" $ do
              SB.addExprLine "ProbsT" $ SB.var pTVar `SB.eq` pTRHS
              SB.addExprLine "ProbsD" $ SB.var pDVar `SB.eq` pDRHS
-}
--        let llArgsT =
{-
        SB.generateLogLikelihood' voteData ((distT, logitT_ps <$> thetaTMultF (SB.dataSetName voteData) q', votes)
                                             :| [(distP, logitP_ps <$> thetaPMultF (SB.dataSetName voteData) q', dVotes)])
-}
        return ()

      addModelIdAndYear :: F.Record (ks V.++ '[ModeledShare])
                        -> F.Record (ModelResultsR ks)
      addModelIdAndYear r = F.rcast $ FT.recordSingleton @BR.Year datYear F.<+> FT.recordSingleton @(MT.ModelId Model) model F.<+> r
      extractResults :: K.KnitEffects r
                     => SC.ResultAction r d SB.DataSetGroupIntMaps () (FS.SFrameRec (ModelResultsR ks))
      extractResults = SC.UseSummary f where
        f summary _ aAndEb_C = do
          let eb_C = fmap snd aAndEb_C
          eb <- K.ignoreCacheTime eb_C
          resultsMap <- K.knitEither $ do
            groupIndexes <- eb
            psIndexIM <- SB.getGroupIndex
              (SB.RowTypeTag @(F.Record rs) "DistrictPS")
              psGroup
              groupIndexes
            let parseAndIndexPctsWith idx g vn = do
                  v <- SP.getVector . fmap CS.percents <$> SP.parse1D vn (CS.paramStats summary)
                  indexStanResults idx $ Vector.map g v
            parseAndIndexPctsWith psIndexIM id $ "PS_DistrictPS_" <> SB.taggedGroupName psGroup
          res :: F.FrameRec (ks V.++ '[ModeledShare]) <- K.knitEither
                                                         $ MT.keyedCIsToFrame @ModeledShare id
                                                         $ M.toList resultsMap
          return $ FS.SFrame $ fmap addModelIdAndYear res
      dataWranglerAndCode :: K.ActionWithCacheTime r (CCESAndPUMS, F.FrameRec rs)
                          -> K.Sem r (SC.DataWrangler (CCESAndPUMS, F.FrameRec rs) SB.DataSetGroupIntMaps (), SB.StanCode)
      dataWranglerAndCode data_C = do
        dat <-  K.ignoreCacheTime data_C
        K.logLE K.Info
          $ "Voter data (CCES) has "
          <> show (FL.fold FL.length $ ccesRows $ fst dat)
          <> " rows."
        let (districts, states) = FL.fold
                                  ((,)
                                   <$> (FL.premap districtKey FL.list)
                                   <*> (FL.premap (F.rgetField @BR.StateAbbreviation) FL.list)
                                  )
                                  $ districtRows $ fst dat
            psKeys = FL.fold (FL.premap F.rcast FL.list) $ snd dat
            groups = groupBuilder psGroup districts states psKeys
--            builderText = SB.dumpBuilderState $ SB.runStanGroupBuilder groups dat
--        K.logLE K.Diagnostic $ "Initial Builder: " <> builderText
        K.logLE K.Info $ show $ zip [1..] $ Set.toList $ FL.fold FL.set states
        K.knitEither $ MRP.buildDataWranglerAndCode groups () dataAndCodeBuilder dat
  let comboDat_C = (,)  <$> dat_C <*> psDat_C
  (dw, stanCode) <- dataWranglerAndCode comboDat_C
  fmap (fmap FS.unSFrame)
    $ MRP.runMRPModel
    clearCaches
    (Just modelDir)
    ("LegDistricts_" <> modelLabel model <> if parallel then "_P" else "")
    jsonDataName
    dw
    stanCode
    "DVOTES_C"
    extractResults
    comboDat_C
    stanParallelCfg
    (Just 1000)
    (Just 0.8)
    (Just 10)


type SLDLocation = (Text, ET.DistrictType, Int)

sldLocationToRec :: SLDLocation -> F.Record [BR.StateAbbreviation, ET.DistrictTypeC, ET.DistrictNumber]
sldLocationToRec (sa, dt, dn) = sa F.&: dt F.&: dn F.&: V.RNil

type ModeledShare = "ModeledShare" F.:-> MT.ConfidenceInterval

type ModelResultsR ks = '[BR.Year] V.++ ks V.++ '[MT.ModelId Model, ModeledShare]


cdGroup :: SB.GroupTypeTag Text
cdGroup = SB.GroupTypeTag "CD"

stateGroup :: SB.GroupTypeTag Text
stateGroup = SB.GroupTypeTag "State"

ageGroup :: SB.GroupTypeTag DT.SimpleAge
ageGroup = SB.GroupTypeTag "Age"

sexGroup :: SB.GroupTypeTag DT.Sex
sexGroup = SB.GroupTypeTag "Sex"

educationGroup :: SB.GroupTypeTag DT.CollegeGrad
educationGroup = SB.GroupTypeTag "Education"

raceGroup :: SB.GroupTypeTag DT.Race5
raceGroup = SB.GroupTypeTag "Race"

hispanicGroup :: SB.GroupTypeTag DT.Hisp
hispanicGroup = SB.GroupTypeTag "Hispanic"

wnhGroup :: SB.GroupTypeTag Bool
wnhGroup = SB.GroupTypeTag "WNH"

wngGroup :: SB.GroupTypeTag Bool
wngGroup = SB.GroupTypeTag "WNG"

{-
race5FromCPS :: F.Record CPSVByCDR -> DT.Race5
race5FromCPS r =
  let race4A = F.rgetField @DT.RaceAlone4C r
      hisp = F.rgetField @DT.HispC r
  in DT.race5FromRaceAlone4AndHisp True race4A hisp
-}
race5FromCensus :: F.Record CPSVByCDR -> DT.Race5
race5FromCensus r =
  let race4A = F.rgetField @DT.RaceAlone4C r
      hisp = F.rgetField @DT.HispC r
  in DT.race5FromRaceAlone4AndHisp True race4A hisp

-- many many people who identify as hispanic also identify as white. So we need to choose.
-- Better to model using both
mergeRace5AndHispanic r =
  let r5 = F.rgetField @DT.Race5C r
      h = F.rgetField @DT.HispC r
  in if (h == DT.Hispanic) then DT.R5_Hispanic else r5

--sldKey r = F.rgetField @BR.StateAbbreviation r <> "-" <> show (F.rgetField @ET.DistrictTypeC r) <> "-" <> show (F.rgetField @ET.DistrictNumber r)
sldKey :: (F.ElemOf rs BR.StateAbbreviation
          ,F.ElemOf rs ET.DistrictTypeC
          ,F.ElemOf rs ET.DistrictNumber)
       => F.Record rs -> SLDLocation
sldKey r = (F.rgetField @BR.StateAbbreviation r
           , F.rgetField @ET.DistrictTypeC r
           , F.rgetField @ET.DistrictNumber r
           )
districtKey r = F.rgetField @BR.StateAbbreviation r <> "-" <> show (F.rgetField @BR.CongressionalDistrict r)
wnh r = (F.rgetField @DT.RaceAlone4C r == DT.RA4_White) && (F.rgetField @DT.HispC r == DT.NonHispanic)
wnhNonGrad r = wnh r && (F.rgetField @DT.CollegeGradC r == DT.NonGrad)
wnhCCES r = (F.rgetField @DT.Race5C r == DT.R5_WhiteNonHispanic) && (F.rgetField @DT.HispC r == DT.NonHispanic)
wnhNonGradCCES r = wnhCCES r && (F.rgetField @DT.CollegeGradC r == DT.NonGrad)

--densityRowFromData :: SB.MatrixRowFromData (F.Record q)
densityRowFromData = SB.MatrixRowFromData "Density" 1 densityPredictor

--densityPredictor :: F.Record rs -> Vector.Vector Double
densityPredictor r = let x = F.rgetField @DT.PopPerSqMile r in Vector.fromList $ [if x < 1e-12 then 0 else Numeric.log x] -- won't matter because Pop will be 0 here

raceAlone4FromRace5 :: DT.Race5 -> DT.RaceAlone4
raceAlone4FromRace5 DT.R5_Other = DT.RA4_Other
raceAlone4FromRace5 DT.R5_Black = DT.RA4_Black
raceAlone4FromRace5 DT.R5_Hispanic = DT.RA4_Other
raceAlone4FromRace5 DT.R5_Asian = DT.RA4_Asian
raceAlone4FromRace5 DT.R5_WhiteNonHispanic = DT.RA4_White

indexStanResults :: (Show k, Ord k)
                 => IM.IntMap k
                 -> Vector.Vector a
                 -> Either Text (Map k a)
indexStanResults im v = do
  when (IM.size im /= Vector.length v)
    $ Left $
    "Mismatched sizes in indexStanResults. Result vector has " <> show (Vector.length v) <> " result and IntMap = " <> show im
  return $ M.fromList $ zip (IM.elems im) (Vector.toList v)
