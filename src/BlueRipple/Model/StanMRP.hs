{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC  -O0 #-}

module BlueRipple.Model.StanMRP
  (
    module BlueRipple.Model.StanMRP
  , RScripts(..)
  , UnwrapJSON(..)
  )
where

import qualified Control.Foldl as FL
import qualified Data.Aeson as A
import qualified Data.Array as Array
import qualified Data.Dependent.HashMap as DHash
import qualified Data.Dependent.Sum as DSum
import qualified Data.IntMap.Strict as IM
import qualified Data.List as List
import Data.List.Extra (nubOrd)
import qualified Data.Map as Map
import qualified Data.Maybe as Maybe
import qualified Data.Set as Set

import qualified Data.Text as T
import qualified Data.Vector as Vec
import qualified Data.Vinyl as V
import qualified Data.Vinyl.TypeLevel as V
import qualified Flat
import Flat.Instances.Vector()
import Flat.Instances.Containers()

import Frames.MapReduce (postMapM)
import qualified Control.MapReduce as MR

import qualified BlueRipple.Utilities.KnitUtils as BR
import qualified BlueRipple.Data.Keyed as BK
import qualified BlueRipple.Configuration as BR

import qualified CmdStan as CS
import qualified CmdStan.Types as CS
import qualified Stan.JSON as SJ
import qualified Stan.Frames as SF
import qualified Stan.Parameters as SP
import qualified Stan.ModelRunner as SM
import Stan.ModelRunner (RScripts)
import qualified Stan.ModelBuilder as SB
import qualified Stan.ModelBuilder.Expressions as SME
import qualified Stan.ModelBuilder.GroupModel as SB
import qualified Stan.ModelBuilder.BuildingBlocks as SB
import qualified Stan.ModelBuilder.FixedEffects as SB
import qualified Stan.ModelBuilder.Distributions as SB
import qualified Stan.ModelConfig as SC
import qualified Stan.RScriptBuilder as SR
import Stan.RScriptBuilder (UnwrapJSON)
import qualified System.Environment as Env

import qualified Knit.Report as K
import qualified Knit.Effect.AtomicCache as K hiding (retrieveOrMake)
import Data.String.Here (here)
import qualified Stan.ModelConfig as SM

type BuilderM md gq = SB.StanBuilderM md gq

buildDataWranglerAndCode :: forall st cd md gq r.(SC.KnitStan st cd r, Typeable md, Typeable gq)
                         => SB.StanGroupBuilderM md gq ()
                         -> SB.StanBuilderM md gq ()
                         -> K.ActionWithCacheTime r md
                         -> K.ActionWithCacheTime r gq
                         -> K.Sem r (SC.DataWrangler md gq SB.DataSetGroupIntMaps (), SB.StanCode)
buildDataWranglerAndCode groupM builderM modelData_C gqData_C = do
  modelDat <- K.ignoreCacheTime modelData_C
  gqDat <- K.ignoreCacheTime gqData_C
  let builderWithWrangler = do
        SB.buildGroupIndexes
        builderM
        modelJsonF <- SB.buildModelJSONFromDataM
        gqJsonF <- SB.buildGQJSONFromDataM
        modelIntMapsBuilder <- SB.modelIntMapsBuilder
        gqIntMapsBuilder <- SB.gqIntMapsBuilder
        let modelWrangle md = (modelIntMapsBuilder md, modelJsonF)
            gqWrangle gq = (gqIntMapsBuilder gq, gqJsonF)
            wrangler :: SC.DataWrangler md gq SB.DataSetGroupIntMaps () =
              SC.Wrangle
              SC.TransientIndex
              modelWrangle
              (Just gqWrangle)
        return wrangler
      resE = SB.runStanBuilder modelDat gqDat groupM builderWithWrangler
  K.knitEither $ fmap (\(bs, dw) -> (dw, SB.code bs)) resE

runMRPModel :: (K.KnitEffects r
               , BR.CacheEffects r
               , Flat.Flat c
               )
            => Bool
            -> SC.RunnerInputNames
            -> SC.StanMCParameters
            -> BR.StanParallel
            -> SC.DataWrangler md gq b ()
            -> SB.StanCode
            -> SM.RScripts
            -> SC.ResultAction r md gq b () c
            -> K.ActionWithCacheTime r md
            -> K.ActionWithCacheTime r gq
            -> K.Sem r (K.ActionWithCacheTime r c)
runMRPModel clearCache runnerInputNames smcParameters stanParallel dataWrangler stanCode rScripts resultAction modelData_C gqData_C =
  K.wrapPrefix "StanMRP.runModel" $ do
  K.logLE K.Info $ "Running: model=" <> SC.rinModel runnerInputNames
    <> " using data=" <> SC.rinData runnerInputNames
    <> maybe "" (" and GQ data=" <>) (SC.rinGQ runnerInputNames)
  let --outputLabel = SC.rinModel runnerInputNames <> "_" <> SC.rinData runnerInputNames
      stancConfig =
        (SM.makeDefaultStancConfig (toString $ SC.rinModelDir runnerInputNames
                                     <> "/" <> SC.rinModel runnerInputNames)) {CS.useOpenCL = False}
      threadsM = Just $ case BR.cores stanParallel of
        BR.MaxCores -> -1
        BR.FixedCores n -> n
  stanConfig <-
    SC.setSigFigs 4
    . SC.noLogOfSummary
--    . SC.noDiagnose
    <$> SM.makeDefaultModelRunnerConfig @BR.SerializerC @BR.CacheData
    runnerInputNames
    (Just (SB.All, SB.stanCodeToStanModel stanCode))
    smcParameters
    (Just stancConfig)
  let resultCacheKey = "stan/MRP/result/" <> SC.mergedPrefix SC.MRFull runnerInputNames <> ".bin"
  when clearCache $ do
    SM.deleteStaleFiles  @BR.SerializerC @BR.CacheData stanConfig [SM.StaleData]
    BR.clearIfPresentD resultCacheKey
  modelDep <- SM.modelDependency SC.MRFull runnerInputNames
  K.logLE (K.Debug 1) $ "modelDep: " <> show (K.cacheTime modelDep)
  K.logLE (K.Debug 1) $ "modelDataDep: " <> show (K.cacheTime modelData_C)
  K.logLE (K.Debug 1) $ "generated quantities DataDep: " <> show (K.cacheTime gqData_C)
  let dataModelDep = (,,) <$> modelDep <*> modelData_C <*> gqData_C
      getResults s () inputAndIndex_C = return ()
--      unwraps = [SR.UnwrapNamed ppName ppName]
  BR.retrieveOrMakeD resultCacheKey dataModelDep $ \_ -> do
    K.logLE K.Diagnostic "Data or model newer then last cached result. (Re)-running..."
    SM.runModel @BR.SerializerC @BR.CacheData
      stanConfig
      rScripts --(SM.Both unwraps)
      dataWrangler
      SC.UnCacheable -- we cannot use a Cacheable index here
      resultAction
      ()
      modelData_C
      gqData_C

-- Basic group declarations, indexes and Json are produced automatically
addGroup :: SB.RowTypeTag r
           -> SB.StanExpr
           -> SB.GroupModel md gq
           -> SB.GroupTypeTag k
           -> Maybe Text
           -> SB.StanBuilderM md gq (SB.StanExpr, SB.StanVar)
addGroup rtt binaryPrior gm gtt mVarSuffix = do
  SB.setDataSetForBindings rtt
  (SB.IntIndex indexSize _) <- SB.rowToGroupIndex <$> SB.indexMap rtt gtt
  let gn = SB.taggedGroupName gtt
      gs t = t <> fromMaybe "" mVarSuffix <> "_" <> gn
  when (indexSize < 2) $ SB.stanBuildError "StanMRP.addGroup: Index with size <2 in MRGroup!"
  let binaryGroup = do
        let en = gs "eps"
        epsVar <- SB.inBlock SB.SBParameters $ SB.stanDeclare en SB.StanReal ""
        let be = SB.bracket
                 $ SB.csExprs (SB.var epsVar :| [SB.negate $ SB.var epsVar])
        let e' = SB.indexBy be gn -- this is weird. But {a,-a} is an array and can be indexed
            modelTerm = SB.vectorFunction "to_vector" e' []
        SB.inBlock SB.SBModel $ do
          let priorE = SB.name en `SB.vectorSample` binaryPrior
          SB.addExprLine "intercept" priorE
        return (modelTerm, epsVar)
  let nonBinaryGroup = do
        let betaVar = SB.StanVar (gs "beta") (SB.StanVector $ SB.NamedDim gn)
            modelTerm = SB.var betaVar --SB.indexBy (SB.name $ gs "beta") gn
        SB.groupModel betaVar gm
        return (modelTerm, betaVar)
  if indexSize == 2 then binaryGroup else nonBinaryGroup

addMultivariateHierarchical :: SB.RowTypeTag r
                            -> SB.GroupModel md gq
                            -> (Bool, SB.StanExpr, SB.StanExpr, SB.StanExpr, Double) -- priors for multinormal parameters
                            -> SB.GroupTypeTag k1
                            -> SB.GroupTypeTag k2
                            -> Maybe Text
                            -> SB.StanBuilderM md gq (SB.StanExpr, SB.StanExpr)
addMultivariateHierarchical rtt binaryGM (mnCentered, mnMuE, mnTauE, mnSigmaE, lkjP) gttExch gttComp mSuffix = do
  SB.setDataSetForBindings rtt
  (SB.IntIndex compN _) <- SB.rowToGroupIndex <$> SB.indexMap rtt gttComp
  when (compN < 2)
    $ SB.stanBuildError "StanMRP.addMultivariateHierarchical: there are <2 components!"
  let nameExch = SB.taggedGroupName gttExch
      nameComp = SB.taggedGroupName gttComp
      suffix = fromMaybe "" mSuffix
      binaryMVH = do
        let ev' = SB.StanVar ("eps" <> suffix <> "_" <> nameComp) (SB.StanVector (SB.NamedDim nameExch))
        ev <- SB.groupModel ev' binaryGM
        let bE = SB.bracket $ SB.csExprs (SB.var ev :| [SB.negate $ SB.var ev])
            indexedE = SB.indexBy bE nameComp
        vectorizedV <- SB.inBlock SB.SBModel
                       $ SB.vectorizeExpr ("eps" <> suffix <> "_" <> nameComp) indexedE (SB.dataSetName rtt)
        return (SB.var vectorizedV, indexedE)
      nonBinaryMVH = do
        let muV = SB.StanVar ("mu" <> suffix <> "_" <> nameComp <> "_" <> nameExch) (SB.StanVector $ SB.NamedDim nameComp)
            tauV = SB.StanVar ("tau" <> suffix <> "_" <> nameComp <> "_" <> nameExch) (SB.StanVector $ SB.NamedDim nameComp)
            sigmaV = SB.StanVar ("sigma" <> suffix <> "_" <> nameComp) SB.StanReal
            lkjV = SB.StanVar ("L" <> suffix <> "_" <> nameComp) (SB.StanCholeskyFactorCorr $ SB.NamedDim nameComp)
            lkjPriorE = SB.function "lkj_corr_cholesky" (SB.scalar (show lkjP) :| [])
            hierHPs = Map.fromList
              [
                (muV, ("", \v -> SB.vectorizedOne nameComp $ SB.var v `SB.vectorSample` mnMuE))
              , (tauV, ("<lower=0>", \v -> SB.vectorizedOne nameComp $ SB.var v `SB.vectorSample` mnTauE))
              , (lkjV, ("<lower=0>", \v -> SB.vectorizedOne nameComp $ SB.var v `SB.vectorSample` lkjPriorE))
              ]
            betaV' = SB.StanVar
                     ("beta" <> suffix <> "_" <> nameComp <> "_" <> nameExch)
                     (SB.StanArray [SB.NamedDim nameExch] $ SB.StanVector $ SB.NamedDim nameComp)
            dpmE =  SB.function "diag_pre_multiply" (SB.var tauV :| [SB.var lkjV])
            vSet = Set.fromList [nameExch, nameComp]
            hm = case mnCentered of
              True ->
                let betaPriorE v = SB.addExprLine "StanMRP.addMultivariateHierarchical"
                      $ SB.vectorized vSet $ SB.var v `SB.vectorSample` SB.function "multi_normal_cholesky" (SB.var muV :| [dpmE])
                in SB.Centered betaPriorE
              False ->
                let nonCenteredF beta@(SB.StanVar sn st) betaRaw = SB.inBlock SB.SBTransformedParameters $ do
                      bv' <- SB.stanDeclare sn st ""
                      SB.stanForLoopB "k" Nothing nameExch
                        $ SB.addExprLine ("nonCentered for multivariateHierarchical: " <> show betaV')
                        $ SB.vectorizedOne nameComp
                        $ SB.var bv' `SB.eq` SB.var muV `SB.plus` (dpmE `SB.times` SB.var betaRaw)
                    rawPriorF v = SB.stanForLoopB "k" Nothing nameExch
                      $ SB.addExprLine "StanMRP.addMultivariateHierarchical"
                      $ SB.vectorizedOne nameComp $ SB.var v `SB.vectorSample` SB.stdNormal
                in SB.NonCentered rawPriorF nonCenteredF
            gm = SB.Hierarchical SB.STZNone hierHPs hm
        betaV <- SB.groupModel betaV' gm
        vectorizedBetaV <- SB.inBlock SB.SBModel $ SB.vectorizeVar betaV (SB.dataSetName rtt)
        return (SB.var vectorizedBetaV, SB.var betaV)
  if compN == 2 then binaryMVH else nonBinaryMVH


addInteractions2 :: SB.RowTypeTag r
                 -> SB.GroupModel md gq
                 -> SB.GroupTypeTag k1
                 -> SB.GroupTypeTag k2
                 -> Maybe Text
                 -> SB.StanBuilderM md gq SB.StanVar
addInteractions2 rtt gm gtt1 gtt2 mSuffix = do
  SB.setDataSetForBindings rtt
  (SB.IntIndex indexSize1 _) <- SB.rowToGroupIndex <$> SB.indexMap rtt gtt1
  (SB.IntIndex indexSize2 _) <- SB.rowToGroupIndex <$> SB.indexMap rtt gtt2
  when (indexSize1 < 2 || indexSize2 < 2) $ SB.stanBuildError "addInteractions2: Index with size < 2"
  let ivn = "beta_" <> SB.taggedGroupName gtt1 <> "_" <> SB.taggedGroupName gtt2 <> maybe "" (("_" <>))  mSuffix
      ivt = SB.StanArray [SB.NamedDim $ SB.taggedGroupName gtt1, SB.NamedDim $ SB.taggedGroupName gtt2] SB.StanReal
      iv' = SB.StanVar ivn ivt
  SB.groupModel iv' gm


data Phantom k = Phantom
addGroupForInteractions :: SB.GroupTypeTag k
                        -> DHash.DHashMap SB.GroupTypeTag Phantom
                        -> DHash.DHashMap SB.GroupTypeTag Phantom
addGroupForInteractions gtt dhm = DHash.insert gtt Phantom dhm

withSome :: (forall k.SB.GroupTypeTag k -> a) -> DHash.Some SB.GroupTypeTag -> a
withSome f (DHash.Some gtt) = f gtt

addInteractions :: Typeable d
                 => SB.RowTypeTag r
                 -> SB.GroupModel env d
                 -> DHash.DHashMap SB.GroupTypeTag Phantom
                 -> Int
                 -> Maybe Text
                 -> SB.StanBuilderM env d [SB.StanVar]
addInteractions rtt gm groups nInteracting mSuffix = do
  SB.setDataSetForBindings rtt
  let groupList = DHash.keys groups -- [Some GroupTypeTag]
  when (nInteracting < 2) $ SB.stanBuildError $ "addInteractions: nInteracting must be at least 2"
  when (nInteracting > length groupList)
    $ SB.stanBuildError
    $ "addInteractions: nInteracting ("
    <> show nInteracting
    <> ") must be at most the number of groups ("
    <> show (length groupList)
    <> ")"
  let indexSize (DHash.Some gtt) = do
        (SB.IntIndex is _) <- SB.rowToGroupIndex <$> SB.indexMap rtt gtt
        return is
  iSizes <- traverse indexSize groupList
  minSize <- SB.stanBuildMaybe "addInteractions: empty groupList" $ FL.fold FL.minimum iSizes
  when (minSize < 2) $ SB.stanBuildError "addInteractions: Index with size < 2"
  let groupCombos = choices groupList nInteracting
      groupNameList = fmap (withSome SB.taggedGroupName)
      betaName l = "beta_" <> (T.intercalate "_" $ groupNameList l) <> maybe "" (("_" <>))  mSuffix
      betaType l = SB.StanArray (fmap SB.NamedDim $ groupNameList l) SB.StanReal
      betaVar l = SB.StanVar (betaName l) (betaType l)
      betaVars = betaVar <$> groupCombos
  SB.groupModel' betaVars gm


-- generate all possible collections of distinct elements of a given length from a list
choices :: [a] -> Int -> [[a]]
choices _ 0 = [[]]
choices [] _ = []
choices (x:xs) n = if (n > length (x:xs))
                   then []
                   else fmap (x:) (choices xs (n-1)) ++ choices xs n

type GroupName = Text

buildIntMapBuilderF :: (k -> Either Text Int) -> (r -> k) -> FL.FoldM (Either Text) r (IM.IntMap k)
buildIntMapBuilderF eIntF keyF = FL.FoldM step (return IM.empty) return where
  step im r = case eIntF $ keyF r of
    Left msg -> Left $ "Indexing error when trying to build IntMap index: " <> msg
    Right n -> Right $ IM.insert n (keyF r) im

data PostStratificationType = PSRaw | PSShare (Maybe SB.StanExpr) deriving (Eq, Show)

-- TODO: order groups differently than the order coming from the built in group sets??
addPostStratification :: (Typeable md, Typeable gq, Ord k) -- ,Typeable r, Typeable k)
                      => (BuilderM md gq a, a -> BuilderM md gq SB.StanExpr) -- (outside of loop, inside of loop)
                      -> Maybe Text
                      -> SB.RowTypeTag rModel
                      -> SB.RowTypeTag rPS
                      -> SB.GroupSet -- groups to sum over
--                      -> Set.Set Text -- subset of groups to loop over
                      -> (rPS -> Double) -- PS weight
                      -> PostStratificationType -- raw or share
                      -> Maybe (SB.GroupTypeTag k) -- group to produce one PS per
                      -> BuilderM md gq SB.StanVar
addPostStratification (preComputeF, psExprF) mNameHead rttModel rttPS sumOverGroups {-sumOverGroups-} weightF psType mPSGroup = do
  -- check that all model groups in environment are accounted for in PS groups
  let psDataSetName = SB.dataSetName rttPS
      modelDataSetName = SB.dataSetName rttModel
      psGroupName = maybe "" SB.taggedGroupName mPSGroup
      uPSGroupName = maybe "" (\x -> "_" <> SB.taggedGroupName x) mPSGroup
      psSuffix = psDataSetName <> uPSGroupName
      namedPS = fromMaybe "PS" mNameHead <> "_" <> psSuffix
      sizeName = "N_" <> namedPS
      indexName = psDataSetName <> "_" <> psGroupName <> "_Index"
  SB.addDeclBinding namedPS $ SB.StanVar sizeName SME.StanInt
  modelRowInfos <- SB.modelRowBuilders <$> get
  gqRowInfos <- SB.gqRowBuilders <$> get
  modelGroupsDHM <- do
    case DHash.lookup rttModel modelRowInfos of
      Nothing -> SB.stanBuildError $ "Modeled data-set (\"" <> modelDataSetName <> "\") is not present in model rowBuilders."
      Just (SB.RowInfo _ _ (SB.GroupIndexes gim) _ _) -> return gim
  psGroupsDHM <- do
     case DHash.lookup rttPS gqRowInfos of
       Nothing -> SB.stanBuildError $ "Post-stratification data-set (\"" <> psDataSetName <> "\") is not present in GQ rowBuilders."
       Just (SB.RowInfo _ _ (SB.GroupIndexes gim) _ _) -> return gim
  checkGroupSubset "Sum Over" "Poststratification data-set" sumOverGroups psGroupsDHM
  checkGroupSubset "Sum Over" "Modeled data-set" sumOverGroups modelGroupsDHM
  toFoldable <- case DHash.lookup rttPS gqRowInfos of
    Nothing -> SB.stanBuildError $ "addPostStratification: RowTypeTag (" <> psDataSetName <> ") not found in GQ rowBuilders."
    Just (SB.RowInfo tf _ _ _ _) -> return tf
  case mPSGroup of
    Nothing -> do
      SB.inBlock SB.SBData $ SB.stanDeclareRHS sizeName SB.StanInt "" $ SB.scalar "1" --SB.addJson rttPS sizeName SB.StanInt "<lower=0>"
      pure ()
    Just gtt -> do
      rims <- SB.gqRowBuilders <$> get
      let psDataMissingErr = "addPostStratification: Post-stratification data-set "
                             <> psDataSetName
                             <> " is missing from GQ rowBuilders."
          groupIndexMissingErr =  "addPostStratification: group "
                                  <> SB.taggedGroupName gtt
                                  <> " is missing from post-stratification data-set ("
                                  <> psDataSetName
                                  <> ")."
          psGroupMissingErr = "Specified group for PS sum (" <> SB.taggedGroupName gtt
                              <> ") is not present in post-stratification data-set: " <> showNames psGroupsDHM --Maps

      (SB.GroupIndexes gis) <- SB.groupIndexes <$> SB.stanBuildMaybe psDataMissingErr (DHash.lookup rttPS rims)
      kToIntE <- SB.groupKeyToGroupIndex <$> SB.stanBuildMaybe groupIndexMissingErr (DHash.lookup gtt gis)
      rowToK <- SB.rowToGroup <$> SB.stanBuildMaybe psGroupMissingErr (DHash.lookup gtt psGroupsDHM)
      SB.addIntMapBuilder rttPS gtt $ SB.buildIntMapBuilderF kToIntE rowToK -- for extracting results
      -- This is hacky.  We need a more principled way to know if re-adding same data is an issue.
      let indexType = SB.StanArray [SB.NamedDim psDataSetName] SB.StanInt
      SB.addColumnMJsonOnce rttPS indexName indexType "<lower=0>" (kToIntE . rowToK)
      SB.addJson rttPS sizeName SB.StanInt "<lower=0>"
        $ SJ.valueToPairF sizeName
        $ fmap (A.toJSON . Set.size)
        $ FL.premapM (kToIntE . rowToK)
        $ FL.generalize FL.set
      SB.addDeclBinding indexName $ SME.StanVar sizeName SME.StanInt
--      SB.addUseBindingToDataSet rttPS indexName $ SB.indexBy (SB.name indexName) psDataSetName
      SB.addUseBindingToDataSet rttPS indexName $ SB.StanVar indexName indexType
      return ()

  let weightArrayType = SB.StanVector $ SB.NamedDim psDataSetName  --SB.StanArray [SB.NamedDim namedPS] $ SB.StanArray groupDims SB.StanReal
  wgtsV <-  SB.addJson rttPS (namedPS <> "_wgts") weightArrayType ""
            $ SJ.valueToPairF (namedPS <> "_wgts")
            $ SJ.jsonArrayF weightF
  SB.inBlock SB.SBGeneratedQuantities $ do
    let errCtxt = "addPostStratification"
        divEq = SB.binOp "/="
    SB.useDataSetForBindings rttPS $ do
--      let eFromDistAndArgs (sDist, args) = SB.familyExp sDist psDataSetName args
      case mPSGroup of
        Nothing -> do
          psV <- SB.stanDeclareRHS namedPS SB.StanReal "" (SB.scalar "0")
          SB.bracketed 2 $ do
            preComputed <- preComputeF
            wgtSumE <- case psType of
                         PSShare _ -> fmap SB.var
                                      $ SB.stanDeclareRHS (namedPS <> "_WgtSum") SB.StanReal "" (SB.scalar "0")
                         _ -> return SB.nullE
            SB.stanForLoopB "n" Nothing psDataSetName $ do
              psExpr <- psExprF preComputed
              e <- SB.stanDeclareRHS ("e" <> namedPS) SB.StanReal "" psExpr --SB.multiOp "+" $ fmap eFromDistAndArgs sDistAndArgs
              SB.addExprLine errCtxt $ SB.var psV `SB.plusEq` (SB.var e `SB.times` SB.var wgtsV)
              case psType of
                PSShare Nothing -> SB.addExprLine errCtxt $ wgtSumE `SB.plusEq` SB.var wgtsV
                PSShare (Just e) -> SB.addExprLine errCtxt $ wgtSumE `SB.plusEq` (e `SB.times` SB.var wgtsV)
                _ -> return ()
            case psType of
              PSShare _ -> SB.addExprLine errCtxt $ SB.var psV `divEq` wgtSumE
              _ -> return ()
          return psV
        Just (SB.GroupTypeTag gn) -> do
--          SB.addUseBinding namedPS $ SB.indexBy (SB.name namedPS) psDataSetName
--          SB.addUseBinding namedPS $ SB.StanVar namedPS (SB.StanVector $ SB.NamedDim psDataSetName) --SB.indexBy (SB.name namedPS) psDataSetName

          let zeroVec = SB.function "rep_vector" (SB.scalar "0" :| [SB.indexSize namedPS])
          psV <- SB.stanDeclareRHS namedPS (SB.StanVector $ SB.NamedDim indexName) "" zeroVec
          SB.bracketed 2 $ do
            preComputed <- preComputeF
            wgtSumE <- case psType of
                         PSShare _ -> fmap SB.var
                                      $ SB.stanDeclareRHS (namedPS <> "_WgtSum") (SB.StanVector (SB.NamedDim indexName)) "" zeroVec
                         _ -> return SB.nullE
            SB.stanForLoopB "n" Nothing psDataSetName $ do
              psExpr <-  psExprF preComputed
              e <- SB.stanDeclareRHS ("e" <> namedPS) SB.StanReal "" psExpr --SB.multiOp "+" $ fmap eFromDistAndArgs sDistAndArgs
              SB.addExprLine errCtxt $ SB.var psV `SB.plusEq` (SB.var e `SB.times` SB.var wgtsV)
              case psType of
                PSShare Nothing -> SB.addExprLine errCtxt $ wgtSumE `SB.plusEq` SB.var wgtsV
                PSShare (Just e) -> SB.addExprLine errCtxt $ wgtSumE `SB.plusEq` (e `SB.times` SB.var wgtsV)
                _ -> return ()
            case psType of
              PSShare _ -> SB.stanForLoopB "n" Nothing indexName $ do
                SB.addExprLine errCtxt $ SB.var psV `divEq` wgtSumE
              _ -> return ()
          return psV

showNames :: DHash.DHashMap SB.GroupTypeTag a -> Text
showNames = T.intercalate "," . fmap (\(gtt DSum.:=> _) -> SB.taggedGroupName gtt) . DHash.toList

checkGroupSubset :: Text
                 -> Text
                 -> DHash.DHashMap SB.GroupTypeTag a
                 -> DHash.DHashMap SB.GroupTypeTag b
                 -> SB.StanBuilderM env d ()
checkGroupSubset n1 n2 gs1 gs2 = do
  let gDiff = DHash.difference gs1 gs2
  when (DHash.size gDiff /= 0)
    $ SB.stanBuildError
    $ n1 <> "(" <> showNames gs1 <> ") is not a subset of "
    <> n2 <> "(" <> showNames gs2 <> ")."
    <> "In " <> n1 <> " but not in " <> n2 <> ": " <> showNames gDiff <> "."
    <> " If this error appears entirely mysterious, try checking the *types* of your group key functions."
