{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Stan.ModelBuilder.Distributions where

--import Stan.ModelBuilder.Expressions as SME
import qualified Stan.ModelBuilder.TypedExpressions.Types as TE
import qualified Stan.ModelBuilder.TypedExpressions.Functions as TE
import qualified Stan.ModelBuilder.TypedExpressions.TypedList as TE
import Stan.ModelBuilder.TypedExpressions.TypedList (TypedList(..))
import qualified Stan.ModelBuilder.TypedExpressions.Expressions as TE
import qualified Stan.ModelBuilder.TypedExpressions.Statements as TE
import qualified Stan.ModelBuilder.TypedExpressions.StanFunctions as TE

import Prelude hiding (All)
import qualified Stan.ModelBuilder.TypedExpressions.Operations as TE

data DistType = Discrete | Continuous deriving (Show, Eq)

data StanDist :: TE.EType -> [TE.EType] -> Type where
  StanDist :: DistType
           -> (TE.UExpr t -> TE.ExprList ts -> TE.UStmt)
           -> (TE.UExpr t -> TE.ExprList ts -> TE.UExpr TE.EReal)
           -> (TE.UExpr t -> TE.ExprList ts -> TE.UExpr TE.EReal)
           -> (TE.ExprList ts -> TE.UExpr t)
           -> StanDist t ts

distType :: StanDist t ts -> DistType
distType (StanDist t _ _ _ _) = t

familySample :: StanDist t ts -> TE.UExpr t -> TE.ExprList ts -> TE.UStmt
familySample (StanDist _ f _ _ _)  = f

familyLDF :: StanDist t ts -> TE.UExpr t -> TE.ExprList ts -> TE.UExpr TE.EReal
familyLDF (StanDist _ _ ldf _ _ ) = ldf

familyLUDF :: StanDist t ts -> TE.UExpr t -> TE.ExprList ts -> TE.UExpr TE.EReal
familyLUDF (StanDist _ _ _ ludf _ ) = ludf

familyRNG :: StanDist t ts -> TE.ExprList ts -> TE.UExpr t
familyRNG (StanDist _ _ _ _ rng ) = rng


normalDist :: (TE.TypeOneOf t [TE.EReal, TE.ECVec], TE.GenSType t) => StanDist t '[t, t]
normalDist = StanDist Continuous sample lpdf lupdf rng
  where
    sample x = TE.sample x TE.normalDensity
    lpdf = TE.densityE TE.normalLPDF
    lupdf = TE.densityE TE.normalLUPDF
    rng = TE.functionE TE.normalRNG

binomialDist' :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
binomialDist' sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    sample gE args = if sampleWithConstants
                     then TE.target $ TE.densityE TE.binomialLPMF gE args
                     else TE.sample gE TE.binomialDensity args
    lpmf = TE.densityE TE.binomialLPMF
    lupmf = TE.densityE TE.binomialLUPMF
    rng = TE.functionE TE.binomialRNG

binomialDist :: StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
binomialDist = binomialDist' False

binomialLogitDist' :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
binomialLogitDist' sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    sample gE args = if sampleWithConstants
                     then TE.target $ TE.densityE TE.binomialLogitLPMF gE args
                     else TE.sample gE TE.binomialLogitDensity args
    lpmf = TE.densityE TE.binomialLogitLPMF
    lupmf = TE.densityE TE.binomialLogitLUPMF
    rng :: TE.ExprList [TE.EArray1 TE.EInt, TE.EReal] -> TE.UExpr (TE.EArray1 TE.EInt)
    rng (tE :> pE :> TNil)= TE.functionE TE.binomialRNG (tE :> TE.functionE TE.invLogit (pE :> TNil) :> TNil)


binomialLogitDist :: StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
binomialLogitDist = binomialLogitDist' False

binomialLogitDistWithConstants :: StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
binomialLogitDistWithConstants = binomialLogitDist' True


--vecTimes = TE.binaryOpE (TE.SElementWise TE.SMultiply)
--vecDivide = TE.binaryOpE (TE.SElementWise TE.SDivide)

betaDist :: StanDist TE.EReal '[TE.EReal, TE.EReal]
betaDist = StanDist Continuous sample lpdf lupdf rng
  where
    sample x = TE.sample x TE.betaDensity
    lpdf = TE.densityE TE.betaLPDF
    lupdf = TE.densityE TE.betaLUPDF
    rng = TE.functionE TE.betaRNG

betaMu :: TE.UExpr TE.EReal -> TE.UExpr TE.EReal -> TE.UExpr TE.EReal
betaMu aE bE = aE `TE.divideE` (aE `TE.plusE` bE)

betaProportionDist :: StanDist TE.EReal '[TE.EReal, TE.EReal]
betaProportionDist = StanDist Continuous sample lpdf lupdf rng
  where
    sample x = TE.sample x TE.betaProportionDensity
    lpdf = TE.densityE TE.betaProportionLPDF
    lupdf = TE.densityE TE.betaProportionLUPDF
    rng = TE.functionE TE.betaProportionRNG

realToSameSizeVec :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.UExpr TE.EReal -> TE.UExpr TE.ECVec
realToSameSizeVec v x = TE.functionE TE.rep_vector (x :> TE.functionE TE.size (v :> TNil) :> TNil)

betaBinomialDist' :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec]
betaBinomialDist' sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    sample x args = if sampleWithConstants
                    then TE.target $ TE.densityE TE.betaBinomialLPMF x args
                    else TE.sample x TE.betaBinomialDensity args
    lpmf = TE.densityE TE.betaBinomialLPMF
    lupmf = TE.densityE TE.betaBinomialLUPMF
    rng = TE.functionE TE.betaBinomialRNG

-- beta-binomial but with the same parameters for every row
scalarBetaBinomialDist' :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal, TE.EReal]
scalarBetaBinomialDist' sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    (StanDist _ sample' lpmf' lupmf' rng') = betaBinomialDist' sampleWithConstants
    sample x  = sample' x . argsToVecs
    lpmf x = lpmf' x . argsToVecs
    lupmf x = lupmf' x . argsToVecs
    rng = rng' . argsToVecs

scaledIntVec :: TE.UExpr TE.EReal
             -> TE.UExpr (TE.EArray1 TE.EInt)
             -> TE.UExpr TE.ECVec
scaledIntVec x iv = x `TE.timesE` intsToVec iv

countScaledBetaBinomialDist :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec]
countScaledBetaBinomialDist sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    f :: TE.UExpr TE.ECVec -> TE.UExpr (TE.EArray1 TE.EInt) -> TE.UExpr TE.ECVec
    f x = TE.binaryOpE (TE.SElementWise TE.SMultiply) x . intsToVec
    sample :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList [TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec] -> TE.UStmt
    sample x (t :> a :> b :> TNil) = if sampleWithConstants
                                     then TE.target $ TE.densityE TE.betaBinomialLPMF x (t :> f a t :> f b t :> TNil)
                                     else TE.sample x TE.betaBinomialDensity (t :> f a t :> f b t :> TNil)
    lpmf :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList '[TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec] -> TE.UExpr TE.EReal
    lpmf x (t :> a :> b :> TNil)  = TE.densityE TE.betaBinomialLPMF x (t :> f a t :> f b t :> TNil)
    lupmf :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList '[TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec] -> TE.UExpr TE.EReal
    lupmf x (t :> a :> b :> TNil)  = TE.densityE TE.betaBinomialLUPMF x (t :> f a t :> f b t :> TNil)
    rng :: TE.ExprList '[TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec] -> TE.UExpr (TE.EArray1 TE.EInt)
    rng (t :> a :> b :> TNil)  = TE.functionE TE.betaBinomialRNG (t :> f a t :> f b t :> TNil)

countScaledScalarBetaBinomialDist :: Bool -> StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal, TE.EReal]
countScaledScalarBetaBinomialDist sampleWithConstants = StanDist Discrete sample lpmf lupmf rng
  where
    (StanDist _ sample' lpmf' lupmf' rng') = countScaledBetaBinomialDist sampleWithConstants
    sample x  = sample' x . argsToVecs
    lpmf x = lpmf' x . argsToVecs
    lupmf x = lupmf' x . argsToVecs
    rng = rng' . argsToVecs

argsToVecs :: TE.ExprList [TE.EArray1 TE.EInt, TE.EReal, TE.EReal] -> TE.ExprList [TE.EArray1 TE.EInt, TE.ECVec, TE.ECVec]
argsToVecs (t :> a :> b :> TNil) = t :> realToSameSizeVec t a :> realToSameSizeVec t b :> TNil

intsToVec :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.UExpr TE.ECVec
intsToVec x = TE.functionE TE.to_vector (x :> TNil)

{-
normallyApproximatedBinomial :: StanDist (TE.EArray1 TE.EInt) '[TE.EArray1 TE.EInt, TE.EReal]
normallyApproximatedBinomial = StanDist Continuous sample lpdf lupdf rng
  where
    mu p t = p `TE.timesE` intsToVec t
--    sigma :: TE.UExpr TE.EReal -> TE.UExpr (TE.EArray1 TE.EInt) -> TE.UExpr TE.ECVec
    sigma p t = TE.functionE (TE.sqrt TE.SReal) (p `TE.timesE` (TE.realE 1 `TE.minusE` p) :> TNil) `TE.timesE` intsToVec t
    sample :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList [TE.EArray1 TE.EInt, TE.EReal] -> TE.UStmt
    sample s (t :> p :> TNil) = TE.sample (intsToVec s) (TE.normalDensity TE.SCVec) (mu p t :> sigma p t :> TNil)
    lpdf :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList [TE.EArray1 TE.EInt, TE.EReal] -> TE.UExpr TE.EReal
    lpdf s (t :> p :> TNil)  = TE.densityE (TE.normalLPDF TE.SCVec) (intsToVec t) (mu p t :> sigma p t :> TNil)
    lupdf :: TE.UExpr (TE.EArray1 TE.EInt) -> TE.ExprList [TE.EArray1 TE.EInt, TE.EReal] -> TE.UExpr TE.EReal
    lupdf s (t :> p :> TNil) = TE.densityE (TE.normalLUPDF TE.SCVec) (intsToVec t) (mu p t :> sigma p t :> TNil)
    rng ::  TE.ExprList [TE.EArray1 TE.EInt, TE.EReal] -> TE.UExpr TE.ECVec
    rng (t :> p :> TNil) = TE.functionE (TE.normalRNG TE.SCVec) (mu p t :> sigma p t > TNil)


normallyApproximatedBinomialLogit :: SME.StanVar -> StanDist SME.StanExpr
normallyApproximatedBinomialLogit tV = StanDist Continuous sample lpdf lupdf rng
  where
    pE lpE = invLogit lpE
    mu lpE = pE lpE `vecTimes` toVec tV
    sigma lpE = TE.functionE (TE.sqrt TE.SCVec) (one $ pE lpE `vecTimes` (SME.scalar "1" `TE.minusE` pE lpE) `vecTimes` toVec tV)
    sample lpE sV = toVec sV `SME.vectorSample` SME.function "normal" (mu lpE :| [sigma lpE])
    lpdf lpE sV = SME.functionWithGivens "normal_lpdf" (one $ toVec sV) (mu lpE :| [sigma lpE])
    lupdf lpE sV = SME.functionWithGivens "normal_lupdf" (one $ toVec sV) (mu lpE :| [sigma lpE])
    rng lpE = SME.function "normal_rng" (mu lpE :| [sigma lpE])
-}

--invLogit :: SME.StanExpr -> SME.StanExpr
--invLogit e = SME.function "inv_logit" (one e)

--    expectation (aE, bE) = aE `SME.divide` (SME.paren $ aE `SME.plus` bE)
{-
-- for priors
normal :: Maybe SME.StanExpr -> SME.StanExpr -> SME.StanExpr
normal mMean sigma = SME.function "normal" (mean :| [sigma]) where
  mean = fromMaybe (SME.scalar "0") mMean

stdNormal :: SME.StanExpr
stdNormal = SME.function "std_normal" (one $ SME.nullE) --normal Nothing (SME.scalar "1")

normalDist :: StanDist (SME.StanExpr, SME.StanExpr)
normalDist = StanDist Continuous sample lpdf lupdf rng
  where
    sample (mean, sigma) yV = SME.target `plusEq` SME.functionWithGivens "normal_lupdf" (one $ SME.var yV) (mean :| [sigma])
    lpdf (mean, sigma) yV = SME.functionWithGivens "normal_lpdf" (one $ SME.var yV) (mean :| [sigma])
    lupdf (mean, sigma) yV = SME.functionWithGivens "normal_lupdf" (one $ SME.var yV) (mean :| [sigma])
    rng (mean, sigma) = SME.function "normal_rng" (mean :| [sigma])
--  expectation (mean, _) = mean

cauchy :: Maybe SME.StanExpr -> SME.StanExpr -> SME.StanExpr
cauchy mMean sigma = SME.function "cauchy" (mean :| [sigma]) where
  mean = fromMaybe (SME.scalar "0") mMean

gamma :: SME.StanExpr -> SME.StanExpr -> SME.StanExpr
gamma alpha beta = SME.function "gamma" (alpha :| [beta])
-}
