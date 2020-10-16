{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module Stan.ModelRunner
  (
    module Stan.ModelRunner
  , module CmdStan
--  , module CmdStan.Types
  ) where

import qualified CmdStan as CS
import qualified CmdStan.Types as CS

import           CmdStan (StancConfig(..)
                         , makeDefaultStancConfig
                         , StanExeConfig(..)
                         , StanSummary
                         )
{-                 
import           CmdStan.Types (StanMakeConfig(..)
                               , StanSummaryConfig(..)
                               )
-}

import qualified Knit.Report as K
import qualified Knit.Effect.Logger            as K
import qualified BlueRipple.Utilities.KnitUtils as BR

import           Control.Monad (when)
import qualified Data.Aeson.Encoding as A
import qualified Data.ByteString.Lazy as BL
import qualified Polysemy as P
import qualified Data.Text as T
import qualified System.Environment as Env
import qualified System.Directory as Dir

data ModelRunnerConfig = ModelRunnerConfig
  { mrcStanMakeConfig :: CS.MakeConfig
  , mrcStanExeConfigF :: Int -> CS.StanExeConfig
  , mrcStanSummaryConfig :: CS.StansummaryConfig
  , mrcModelDir :: T.Text
  , mrcModel :: T.Text
  , mrcDatFile :: T.Text
  , mrcOutputPrefix :: T.Text
  , mrcNumChains :: Int
  , mrcLogSummary :: Bool
  }

-- produce JSON from the data 
type JSONAction r a = a -> K.Sem r A.Encoding

-- produce a result of type b from the data and the model summary
-- NB: the cache time will give you newest of data and stan output
type ResultAction r a b = CS.StanSummary -> K.ActionWithCacheTime r a -> K.Sem r b  

addDirT :: T.Text -> T.Text -> T.Text
addDirT dir fp = dir <> "/" <> fp

addDirFP :: FilePath -> FilePath -> FilePath
addDirFP dir fp = dir ++ "/" ++ fp

defaultDatFile :: T.Text -> FilePath
defaultDatFile modelNameT = (T.unpack modelNameT) ++ ".json"      

modelFile :: T.Text -> FilePath
modelFile modelNameT =  (T.unpack modelNameT) ++ ".stan"

outputFile :: T.Text -> Int -> FilePath
outputFile outputFilePrefix chainIndex = (T.unpack outputFilePrefix ++ "_" ++ show chainIndex ++ ".csv")

makeDefaultModelRunnerConfig :: P.Member (P.Embed IO) r
                             => T.Text
                             -> T.Text
                             -> Maybe T.Text
                             -> Maybe T.Text 
                             -> Int
                             -> Maybe Int
                             -> Maybe Int
                             -> Maybe CS.StancConfig
                             -> K.Sem r ModelRunnerConfig
makeDefaultModelRunnerConfig modelDirT modelNameT datFileM outputFilePrefixM numChains numWarmupM numSamplesM stancConfigM = do
  let modelDirS = T.unpack modelDirT
      outputFilePrefix = maybe modelNameT id outputFilePrefixM
      datFileS = maybe (defaultDatFile modelNameT) T.unpack datFileM
  stanMakeConfig' <- K.liftKnit $ CS.makeDefaultMakeConfig (T.unpack $ addDirT modelDirT modelNameT)
  let stanMakeConfig = stanMakeConfig' { CS.stancFlags = stancConfigM }
      stanExeConfigF chainIndex = (CS.makeDefaultSample (T.unpack modelNameT) chainIndex)
                                  { CS.inputData = Just (addDirFP (modelDirS ++ "/data") $ datFileS)
                                  , CS.output = Just (addDirFP (modelDirS ++ "/output") $ outputFile outputFilePrefix chainIndex) 
                                  , CS.numSamples = numSamplesM
                                  , CS.numWarmup = numWarmupM
                                  }
  let stanOutputFiles = fmap (\n -> outputFile outputFilePrefix n) [1..numChains]
  stanSummaryConfig <- K.liftKnit $ CS.useCmdStanDirForStansummary (CS.makeDefaultSummaryConfig $ fmap (addDirFP (modelDirS ++ "/output")) stanOutputFiles)
  return $ ModelRunnerConfig stanMakeConfig stanExeConfigF stanSummaryConfig modelDirT modelNameT (T.pack datFileS) outputFilePrefix numChains True



runModel :: (K.KnitEffects r,  K.CacheEffectsD r)
         => ModelRunnerConfig
         -> JSONAction r a
         -> ResultAction r a b
         -> K.ActionWithCacheTime r a
         -> K.Sem r b
runModel config makeJSON makeResult cachedA = do
  let modelNameS = T.unpack $ mrcModel config
      modelDirS = T.unpack $ mrcModelDir config
      outputFiles = fmap (\n -> outputFile (mrcOutputPrefix config) n) [1..(mrcNumChains config)]
  checkClangEnv
  checkDir (mrcModelDir config) >>= K.knitMaybe "Model directory is missing!" 
  createDirIfNecessary (mrcModelDir config <> "/data")
  createDirIfNecessary (mrcModelDir config <> "/output")
  json_C <- do
    let jsonFP = addDirFP (modelDirS ++ "/data") $ T.unpack $ mrcDatFile config 
    curJSON_C <- BR.fileDependency jsonFP
    BR.updateIf curJSON_C cachedA $ \a -> do
      K.logLE K.Info $ "JSON data in \"" <> (T.pack jsonFP) <> "\" is missing or out of date.  Rebuilding..."
      makeJSON a >>= K.liftKnit . BL.writeFile jsonFP . A.encodingToLazyByteString
      K.logLE K.Info "Finished rebuilding JSON."
  stanOutput_C <-  do
    curStanOutputs_C <- fmap BR.oldestUnit $ traverse (BR.fileDependency . addDirFP (modelDirS ++ "/output")) outputFiles
    curModel_C <- BR.fileDependency (addDirFP modelDirS $ modelFile $ mrcModel config)
    let runStanDeps = (,) <$> json_C <*> curModel_C
        runOneChain chainIndex = do 
          let exeConfig = (mrcStanExeConfigF config) chainIndex          
          K.logLE K.Info $ "Running " <> T.pack modelNameS <> " for chain " <> (T.pack $ show chainIndex)
          K.logLE K.Diagnostic $ "Command: " <> T.pack (CS.toStanExeCmdLine exeConfig)
          K.liftKnit $ CS.stan (addDirFP modelDirS modelNameS) exeConfig
          K.logLE K.Info $ "Finished chain " <> (T.pack $ show chainIndex)
    res_C <- BR.updateIf (fmap Just curStanOutputs_C) runStanDeps $ \_ ->  do
      K.logLE K.Info "Stan outputs older than input data or model.  Rebuilding Stan exe and running."
      K.logLE K.Info $ "Make CommandLine: " <> (T.pack $ CS.makeConfigToCmdLine (mrcStanMakeConfig config))
      K.liftKnit $ CS.make (mrcStanMakeConfig config)
      maybe Nothing (const $ Just ()) . sequence <$> (K.sequenceConcurrently $ fmap runOneChain [1..(mrcNumChains config)])
    K.ignoreCacheTime res_C >>= K.knitMaybe "There was an error running an MCMC chain." 
    return res_C
  K.logLE K.Diagnostic $ "Summary command: "
    <> (T.pack $ (CS.cmdStanDir . mrcStanMakeConfig $ config) ++ "/bin/stansummary")
    <> " "
    <> T.intercalate " " (fmap T.pack (CS.stansummaryConfigToCmdLine (mrcStanSummaryConfig config)))
  summary <- K.liftKnit $ CS.stansummary (mrcStanSummaryConfig config)
  when (mrcLogSummary config) $ K.logLE K.Info $ "Stan Summary:\n" <> (T.pack $ CS.unparsed summary)
  let resultDeps = const <$> cachedA <*> stanOutput_C
  makeResult summary resultDeps 

checkClangEnv ::  (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r) => K.Sem r ()
checkClangEnv = K.wrapPrefix "checkClangEnv" $ do
  clangBinDirM <- K.liftKnit $ Env.lookupEnv "CLANG_BINDIR"
  case clangBinDirM of
    Nothing -> K.logLE K.Info "CLANG_BINDIR not set. Using existing path for clang."
    Just clangBinDir -> do
      curPath <- K.liftKnit $ Env.getEnv "PATH"
      K.logLE K.Info $ "Current path: " <> (T.pack $ show curPath) <> ".  Adding " <> (T.pack $ show clangBinDir) <> " for llvm clang."
      K.liftKnit $ Env.setEnv "PATH" (clangBinDir ++ ":" ++ curPath)    
                           
createDirIfNecessary
  :: (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r)
  => T.Text
  -> K.Sem r ()
createDirIfNecessary dir = K.wrapPrefix "createDirIfNecessary" $ do
  K.logLE K.Diagnostic $ "Checking if cache path (\"" <> dir <> "\") exists."
  existsB <- P.embed $ (Dir.doesDirectoryExist (T.unpack dir))
  case existsB of
    True -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" exists."
      return ()
    False -> do
      K.logLE K.Info
        $  "Cache directory (\""
        <> dir
        <> "\") not found. Atttempting to create."
      P.embed
        $ Dir.createDirectoryIfMissing True (T.unpack dir)
{-# INLINEABLE createDirIfNecessary #-}

checkDir
  :: (P.Members '[P.Embed IO] r, K.LogWithPrefixesLE r)
  => T.Text
  -> P.Sem r (Maybe ())
checkDir dir =  K.wrapPrefix "checkDir" $ do
  K.logLE K.Diagnostic $ "Checking if cache path (\"" <> dir <> "\") exists."
  existsB <- P.embed $ (Dir.doesDirectoryExist (T.unpack dir))
  case existsB of
    True -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" exists."
      return $ Just ()
    False -> do
      K.logLE K.Diagnostic $ "\"" <> dir <> "\" is missing."
      return Nothing
