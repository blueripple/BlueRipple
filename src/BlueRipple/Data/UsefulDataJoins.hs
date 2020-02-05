{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DataKinds                 #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE PolyKinds                 #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE GADTs                     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE TypeApplications          #-}
{-# LANGUAGE TypeFamilies              #-}
{-# LANGUAGE TypeOperators             #-}
{-# LANGUAGE QuasiQuotes               #-}
{-# LANGUAGE StandaloneDeriving        #-}
{-# LANGUAGE TupleSections             #-}

{-# OPTIONS_GHC  -fplugin=Polysemy.Plugin  #-}

module BlueRipple.Data.UsefulDataJoins where

import qualified Control.Foldl                 as FL
import           Control.Monad                  ( join )
import qualified Data.Array                    as A
import           Data.Function                  ( on )
import qualified Data.List                     as L
import qualified Data.Set                      as S
import qualified Data.Map                      as M
import           Data.Maybe                     ( isJust
                                                , catMaybes
                                                )

import qualified Data.Text                     as T
import qualified Data.Serialize                as SE

import qualified Frames                        as F
import qualified Frames.Melt                   as F
import qualified Frames.InCore                 as FI
import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V
import qualified Data.Discrimination.Grouping  as G


import qualified Control.MapReduce             as MR
import qualified Frames.Transform              as FT
import qualified Frames.Folds                  as FF
import qualified Frames.MapReduce              as FMR
import qualified Frames.Enumerations           as FE
import qualified Frames.Utils                  as FU
import qualified Frames.Serialize              as FS

import qualified Graphics.Vega.VegaLite        as GV
import qualified Knit.Report                   as K

import           BlueRipple.Utilities.KnitUtils

import qualified Statistics.Types              as ST
import           GHC.Generics                   ( Generic )

import qualified BlueRipple.Data.DataFrames    as BR
import qualified BlueRipple.Data.DemographicTypes
                                               as BR
--import qualified BlueRipple.Data.HouseElectionTotals as BR
import qualified BlueRipple.Data.PrefModel     as BR
--import qualified BlueRipple.Data.PrefModel.SimpleAgeSexEducation as BR
import qualified BlueRipple.Model.TurnoutAdjustment
                                               as BR
--import qualified BlueRipple.Model.MRP_Pref as BR

import qualified BlueRipple.Utilities.KnitUtils
                                               as BR

type ASECols = [BR.SimpleAgeC, BR.SexC, BR.CollegeGradC]

demoWithAdjTurnoutByCD
  :: forall es r
   . (K.KnitOne r, K.Members es r)
  => K.Cached es (F.FrameRec (BR.ACSKeys V.++ ASECols V.++ '[BR.ACSCount]))
  -> K.Cached
       es
       ( F.FrameRec
           ( '[BR.Year]
               V.++
               ASECols
               V.++
               '[BR.Population, BR.Citizen, BR.Registered, BR.Voted]
           )
       )
  -> K.Cached es [BR.StateTurnout]
  -> K.Sem
       r
       ( F.FrameRec
           ( BR.ACSKeys
               V.++
               ASECols
               V.++
               '[BR.ACSCount, BR.VotedPctOfAll]
           )
       )
demoWithAdjTurnoutByCD demoCA turnoutCA stateTurnoutCA = do
  demo         <- K.useCached demoCA
  turnout      <- K.useCached turnoutCA
  stateTurnout <- K.useCached stateTurnoutCA
  let demoByState =
        let unpack = MR.noUnpack
            assign =
              FMR.assignKeysAndData
                @('[BR.Year, BR.StateAbbreviation] V.++ ASECols)
                @'[BR.ACSCount]
            reduce = FMR.foldAndAddKey $ FF.foldAllConstrained @Num FL.sum
        in  FL.fold (FMR.concatFold $ FMR.mapReduceFold unpack assign reduce)
                    demo
      demoWithUnAdjTurnoutByState =
        catMaybes $ fmap F.recMaybe $ F.leftJoin @('[BR.Year] V.++ ASECols)
          demoByState
          turnout
  demoWithAdjTurnoutByState <- FL.foldM
    (BR.adjTurnoutFold @BR.ACSCount @BR.VotedPctOfAll stateTurnout)
    demoWithUnAdjTurnoutByState
  return
    $ F.toFrame
    $ fmap F.rcast
    $ catMaybes
    $ fmap F.recMaybe
    $ F.leftJoin @('[BR.Year, BR.StateAbbreviation] V.++ ASECols)
        demo
        demoWithAdjTurnoutByState

