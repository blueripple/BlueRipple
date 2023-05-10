{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UnicodeSyntax #-}
--{-# LANGUAGE NoStrictData #-}

module BlueRipple.Model.Demographic.EnrichCensus
  (
    module BlueRipple.Model.Demographic.EnrichCensus
  )
where

import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.GeographicTypes as GT
import qualified BlueRipple.Data.DataFrames as BRDF
import qualified BlueRipple.Model.Demographic.StanModels as SM
import qualified BlueRipple.Model.Demographic.DataPrep as DDP
import qualified BlueRipple.Model.Demographic.EnrichData as DED
import qualified BlueRipple.Model.Demographic.MarginalStructure as DMS

import qualified BlueRipple.Data.Keyed as Keyed

import qualified BlueRipple.Data.CensusLoaders as BRC
import qualified BlueRipple.Data.CensusTables as BRC

import qualified BlueRipple.Data.ACS_PUMS as PUMS
import qualified BlueRipple.Data.DemographicTypes as DT
import qualified BlueRipple.Data.DataFrames as BRDF
import qualified BlueRipple.Utilities.KnitUtils as BRK

import qualified Knit.Report as K
import qualified Knit.Utilities.Streamly as KS

import qualified Stan.ModelRunner as SMR

import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Vector.Unboxed as VU
import qualified Data.Vinyl.TypeLevel as V
import qualified Control.Foldl as FL
import qualified Frames as F
import qualified Frames.Melt as F
import qualified Frames.Transform as FT
import qualified Frames.Streamly.Transform as FST
import qualified Frames.MapReduce as FMR
import qualified Control.MapReduce as MR

import Control.Lens (view, Lens')
import BlueRipple.Model.Demographic.TPModel3 (ModelConfig(distribution))

type CensusASERR = [BRDF.Year, GT.StateAbbreviation, GT.StateFIPS, GT.DistrictTypeC, GT.DistrictName
                   , DT.Age5FC, DT.SexC, DT.Education4C, DT.Race5C, DT.PWPopPerSqMile, DT.PopCount
                   ]


{-
1. Correct marginal structure within joint for the model.
2. Recode loaded block-group data to correct inputs for model (cached district-demographics -> cached recoded district-demographics)
2a. Recode values (block-group categories to ACS categories)
2b. Build product distribution
3. Model runner (when necessary), along with correct design-matrix and ACS row-fold(s).
4. Model applier to recoded census (cached model-results + cached recoded-district-demographics -> cached enriched district demographics)
-}
type SR = [DT.SexC, DT.Race5C]
type SER = [DT.SexC, DT.Education4C, DT.Race5C]
type ASR = [DT.Age5FC, DT.SexC, DT.Race5C]
type ASER = [DT.Age5FC, DT.SexC, DT.Education4C, DT.Race5C]

msSER_ASR :: Monoid w
          => Lens' w Double
          -> (Map (F.Record '[DT.Education4C]) w -> Map (F.Record '[DT.Age5FC]) w -> Map (F.Record '[DT.Education4C], F.Record '[DT.Age5FC]) w)
          -> DMS.MarginalStructure w (F.Record ASER)
msSER_ASR wl innerProduct = DMS.reKeyMarginalStructure
                            (F.rcast @[DT.SexC, DT.Race5C, DT.Education4C, DT.Age5FC])
                            (F.rcast @ASER)
                            $ DMS.combineMarginalStructuresF @'[DT.SexC, DT.Race5C]
                            wl innerProduct (DMS.identityMarginalStructure wl) (DMS.identityMarginalStructure wl)

type LDRecoded ks = BRDF.Year ': BRC.LDLocationR V.++ ks V.++ [DT.PopCount, DT.PWPopPerSqMile]

recodeASR :: F.FrameRec (BRC.CensusRow BRC.LDLocationR BRC.ExtensiveDataR [BRC.Age14C, DT.SexC, BRC.RaceEthnicityC])
          -> F.FrameRec (LDRecoded ASR)
recodeASR = fmap F.rcast . FL.fold reFld . FL.fold ageFld
  where
    ageFld = FMR.concatFold
             $ FMR.mapReduceFold
             FMR.noUnpack
             (FMR.assignKeysAndData @(BRDF.Year ': BRC.LDLocationR V.++ '[DT.SexC, BRC.RaceEthnicityC]))
             (FMR.makeRecsWithKey id $ FMR.ReduceFold $ const BRC.age14ToAge5FFld)
    reFld = FMR.concatFold
             $ FMR.mapReduceFold
             FMR.noUnpack
             (FMR.assignKeysAndData @(BRDF.Year ': BRC.LDLocationR V.++ '[DT.SexC, DT.Age5FC]))
             (FMR.makeRecsWithKey id $ FMR.ReduceFold $ const BRC.reToR5Fld)


recodeSER ::  F.FrameRec (BRC.CensusRow BRC.LDLocationR BRC.ExtensiveDataR [DT.SexC, DT.Education4C, BRC.RaceEthnicityC])
          -> F.FrameRec (LDRecoded SER)
recodeSER = fmap F.rcast . FL.fold reFld
  where
    reFld = FMR.concatFold
             $ FMR.mapReduceFold
             FMR.noUnpack
             (FMR.assignKeysAndData @(BRDF.Year ': BRC.LDLocationR V.++ '[DT.SexC, DT.Education4C]))
             (FMR.makeRecsWithKey id $ FMR.ReduceFold $ const BRC.reToR5Fld)


{-
ser_asr_tableProductWithDensity :: F.FrameRec (LDRecoded SER) -> F.FrameRec (LDRecoded ASR) -> F.FrameRec (LDRecoded ASER)
ser_asr_tableProductWithDensity ser asr = DMS.tableProductWithData 1 serWD asrWD
  where
    tcwd :: (F.ElemOf rs DT.PopCount, F.ElemOf rs DT.PWPopPerSqMile) => F.Record rs -> DMS.TableCellWithData
    tcwd r = TableCellWithData (view DT.popCount r) (VU.singleton $ view DT.pWPopPerSqMile r)
    serWD = FL.fold (FL.premap (\r -> (F.rcast @SR r, tcwd r)) FL.map) ser
    asrWD = FL.fold (FL.premap (\r -> (F.rcast @SR r, tcwd r)) FL.map) asr
    reFrame (outer, )
-}
{-
censusASR_SER_Products :: K.Sem r
                       => Text
                       -> K.ActionWithCacheTime r (BRC.CensusTables BRC.LDLocationR BRC.ExtensiveDataR BRC.Age14C DT.SexC DT.Education4C BRC.RaceEthnicityC)
                       -> K.ActionWithCacheTime r (F.FrameRec CensusASERR)
censusASR_SER_Products cacheKey censusTables_C = BRK.retrieveOrMakeFrame cacheKey censusTables_C f
  where
    f (BRC.CensusTables asr _ ser _) = do
      let toMap kF dF = M.fromList
                        <$> MR.mapReduceFold
                        MR.noUnpack
                        (MR.assign kF dF)
                        (MR.foldAndLabel F.toFrame (,))
          keyF = F.rcast @[BRDF.Year, GT.StateAbbreviation, GT.StateFIPS, GT.DistrictTypeC, GT.DistrictName]
          asrF = F.rcast @[DT.Age5FC, DT.SexC, DT.Race5C, DT.PopCount, DT.PWPopPerSqMile]
          serF = F.rcast @[DT.SexC, DT.Education4C, DT.Race5C, DT.PopCount, DT.PWPopPerSqMile]
          asrMap = toMap keyF asrF (recodeASR asr)
          serMap = toMap keyF asrF (recodeSER ser)
      whenMatchedF k asr ser =
-}
{-
type CensusCASERR = BRC.CensusRow BRC.LDLocationR BRC.ExtensiveDataR [DT.CitizenC, DT.Age4C, DT.SexC, DT.Education4C, BRC.RaceEthnicityC]
type CensusASERRecodedR = BRC.LDLocationR
                          V.++ BRC.ExtensiveDataR
                          V.++ [DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.RaceAlone4C, DT.HispC, DT.PopCount, DT.PopPerSqMile]
-}

{-
-- Step 1
-- NB all this data is without a year field. So this step needs to be done for each year
enrichCensusData :: SM.AgeStateModelResult -> BRC.LoadedCensusTablesByLD -> K.Sem r (F.FrameRec CensusCASERR)
enrichCensusData amr censusTables = do
  enrichedViaModel <- KS.streamlyToKnit
                      $ DED.enrichFrameFromBinaryModel @DT.SimpleAge @BRC.Count
                      amr
                      (F.rgetField @BRDF.StateAbbreviation)
                      DT.EqualOrOver
                      DT.Under
                      (BRC.sexEducationRace censusTables)
  let rowSumFld = DED.desiredRowSumsFld @DT.Age4C @BRC.Count @[BRDF.StateAbbreviation, DT.SexC, DT.RaceAlone4C, DT.HispC] allSimpleAges DT.age4ToSimple
  let ncFld = DED.nearestCountsFrameFld @BRC.Count @DT.SimpleAgeC @DT.Education4C (DED.nearestCountsFrameIFld DED.nearestCountsKL) desiredRowSumLookup allEdus
-}
