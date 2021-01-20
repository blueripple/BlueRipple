{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{-# OPTIONS_GHC -O0 #-}
module Main where

import qualified Data.Text as T
import qualified Data.Map as M
import qualified Data.Serialize                as S
import qualified Data.Binary                as B
import qualified Data.Binary.Builder                as B
import qualified Data.Binary.Put                as B
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Builder as BB
import qualified ByteString.StrictBuilder as BSB
import qualified Knit.Report as K
import qualified Knit.Utilities.Streamly as K
import qualified Knit.Report.Cache as KC
import qualified Knit.Effect.AtomicCache as KAC
import qualified Knit.Effect.Serialize as KS
import qualified Polysemy as P
import qualified Control.Foldl                 as FL
import qualified BlueRipple.Data.DataFrames    as DS.Loaders
import qualified BlueRipple.Data.ACS_PUMS as PUMS
import qualified BlueRipple.Data.ACS_PUMS_Loader.ACS_PUMS_Frame as PUMS
import           Data.String.Here               ( i, here )
import qualified Data.Word as Word
import qualified Frames as F
import qualified Data.Vinyl.TypeLevel as V
import qualified Data.Vinyl as V
import qualified Frames.Streamly.CSV as FStreamly
import qualified Frames.Streamly.InCore as FStreamly
import qualified Frames.Serialize as FS
import qualified Frames.MapReduce as FMR
import qualified BlueRipple.Data.LoadersCore as Loaders
import qualified BlueRipple.Utilities.KnitUtils as BR
import qualified BlueRipple.Utilities.FramesUtils as BRF
import qualified Frames.CSV                     as Frames
import qualified Streamly.Data.Fold            as Streamly.Fold
import qualified Streamly.Internal.Data.Fold.Types            as Streamly.Fold
import qualified Streamly.Internal.Data.Fold            as Streamly.Fold
import qualified Streamly.Prelude              as Streamly
import qualified Streamly.Internal.Prelude              as Streamly
import qualified Streamly              as Streamly
import qualified Streamly.Internal.FileSystem.File
                                               as Streamly.File
import qualified Streamly.External.ByteString  as Streamly.ByteString

import qualified Streamly.Internal.Data.Array  as Streamly.Data.Array
import qualified Streamly.Internal.Memory.Array as Streamly.Memory.Array
import qualified Control.DeepSeq as DeepSeq

yamlAuthor :: T.Text
yamlAuthor = [here|
- name: Adam Conner-Sax
- name: Frank David
|]

templateVars =
  M.fromList [("lang", "English")
             , ("site-title", "Blue Ripple Politics")
             , ("home-url", "https://www.blueripplepolitics.org")
--  , ("author"   , T.unpack yamlAuthor)
             ]


pandocTemplate = K.FullySpecifiedTemplatePath "pandoc-templates/blueripple_basic.html"

main :: IO ()
main= do

  pandocWriterConfig <- K.mkPandocWriterConfig pandocTemplate
                                               templateVars
                                               K.mindocOptionsF
  let  knitConfig = (K.defaultKnitConfig Nothing)
        { K.outerLogPrefix = Just "Testbed.Main"
        , K.logIf = K.logDiagnostic
        , K.pandocWriterConfig = pandocWriterConfig
        }
  resE <- K.knitHtml knitConfig makeDoc
  case resE of
    Right htmlAsText ->
      K.writeAndMakePathLT "testbed.html" htmlAsText
    Left err -> putStrLn $ "Pandoc Error: " ++ show err


encodeOne :: S.Serialize a => a -> BB.Builder
encodeOne !x = S.execPut $ S.put x

bEncodeOne :: B.Binary a => a -> BB.Builder
bEncodeOne !x = B.fromLazyByteString $ B.runPut $ B.put x


bldrToCT  = Streamly.ByteString.toArray . BL.toStrict . BB.toLazyByteString

encodeBSB :: S.Serialize a => a -> BSB.Builder
encodeBSB !x = BSB.bytes $! encodeBS x

bEncodeBSB :: B.Binary a => a -> BSB.Builder
bEncodeBSB !x = BSB.bytes $! bEncodeBS x

encodeBS :: S.Serialize a => a -> BS.ByteString
encodeBS !x = S.runPut $! S.put x

bEncodeBS :: B.Binary a => a -> BS.ByteString
bEncodeBS !x = BL.toStrict $ B.runPut $! B.put x


bsbToCT  = Streamly.ByteString.toArray . BSB.builderBytes


data Accum b = Accum { count :: !Int, bldr :: !b }

streamlySerializeF :: forall c bldr m a ct.(Monad m, Monoid bldr, c a, c Word.Word64)
                   => (forall b. c b => b -> bldr)
                   -> (bldr -> ct)
                   -> Streamly.Fold.Fold m a ct
streamlySerializeF encodeOne bldrToCT = Streamly.Fold.Fold step initial extract where
  step (Accum n b) !a = return $ Accum (n + 1) (b <> encodeOne a)
  initial = return $ Accum 0 mempty
  extract (Accum n b) = return $ bldrToCT $ encodeOne (fromIntegral @Int @Word.Word64 n) <> b
{-# INLINEABLE streamlySerializeF #-}

toCT :: BSB.Builder -> Int -> Streamly.Memory.Array.Array Word8
toCT bldr n = bsbToCT $ encodeBSB (fromIntegral @Int @Word.Word64 n) <> bldr

bToCT :: BSB.Builder -> Int -> Streamly.Memory.Array.Array Word8
bToCT bldr n = bsbToCT $ bEncodeBSB (fromIntegral @Int @Word.Word64 n) <> bldr

streamlySerializeF2 :: forall c bldr m a ct.(Monad m, Monoid bldr, c a, c Word.Word64)
                   => (forall b. c b => b -> bldr)
                   -> (bldr -> ct)
                   -> Streamly.Fold.Fold m a ct
streamlySerializeF2 encodeOne bldrToCT =
  let fBuilder = Streamly.Fold.Fold step initial return where
        step !b !a = return $ b <> encodeOne a
        initial = return mempty
      toCT' bldr n = bldrToCT $ encodeOne (fromIntegral @Int @Word.Word64 n) <> bldr
  in toCT' <$> fBuilder <*> Streamly.Fold.length
--        extract (Accum n b) = return $ bldrToCT $ encodeOne (fromIntegral @Int @Word.Word64 n) <> b
{-# INLINEABLE streamlySerializeF2 #-}

toStreamlyFold :: Monad m => FL.Fold a b -> Streamly.Fold.Fold m a b
toStreamlyFold (FL.Fold step init done) = Streamly.Fold.mkPure step init done

toStreamlyFoldM :: Monad m => FL.FoldM m a b -> Streamly.Fold.Fold m a b
toStreamlyFoldM (FL.FoldM step init done) = Streamly.Fold.mkFold step init done

makeDoc :: forall r. (K.KnitOne r,  K.CacheEffectsD r) => K.Sem r ()
makeDoc = do
  let pumsCSV = "../bigData/test/acs100k.csv"
      dataPath = (Loaders.LocalData $ T.pack $ pumsCSV)
  K.logLE K.Info "Testing File.toBytes..."
  let rawBytesS =  Streamly.File.toBytes pumsCSV
  rawBytes <-  K.streamlyToKnit $ Streamly.fold Streamly.Fold.length rawBytesS
  K.logLE K.Info $ "raw PUMS data has " <> (T.pack $ show rawBytes) <> " bytes."
  K.logLE K.Info "Testing readTable..."
  let sPumsRawRows :: Streamly.SerialT K.StreamlyM PUMS.PUMS_Raw2
        = FStreamly.readTableOpt Frames.defaultParser pumsCSV
  iRows <-  K.streamlyToKnit $ Streamly.fold Streamly.Fold.length sPumsRawRows
  K.logLE K.Info $ "raw PUMS data has " <> (T.pack $ show iRows) <> " rows."
  K.logLE K.Info "Testing Frames.Streamly.inCoreAoS:"
  fPums <- K.streamlyToKnit $ FStreamly.inCoreAoS sPumsRawRows
  K.logLE K.Info $ "raw PUMS frame has " <> show (FL.fold FL.length fPums) <> " rows."
  -- Previous goes up to 28MB, looks like via doubling.  Then to 0 (collects fPums after counting?)
  -- This one then climbs to 10MB, rows are smaller.  No large leaks.
  K.logLE K.Info "Testing Frames.Streamly.inCoreAoS with row transform:"
  fPums' <- K.streamlyToKnit $ FStreamly.inCoreAoS $ Streamly.map PUMS.transformPUMSRow' sPumsRawRows
  K.logLE K.Info $ "transformed PUMS frame has " <> show (FL.fold FL.length fPums') <> " rows."
  K.logLE K.Info "loadToRecStream..."
  let sRawRows2 :: Streamly.SerialT K.StreamlyM PUMS.PUMS_Raw2
        = DS.Loaders.loadToRecStream Frames.defaultParser pumsCSV (const True)
  iRawRows2 <-  K.streamlyToKnit $ Streamly.fold Streamly.Fold.length sRawRows2
  K.logLE K.Info $ "PUMS data (via loadToRecStream) has " <> show iRows <> " rows."
  K.logLE K.Info $ "transform and load that stream to frame..."
  let countFold = Loaders.runningCountF "reading..." (\n -> "read " <> show (250000 * n) <> " rows") "finished"
      sPUMSRunningCount = Streamly.map PUMS.transformPUMSRow'
                          $ Streamly.tapOffsetEvery 250000 250000 countFold sRawRows2
  fPums'' <- K.streamlyToKnit $ FStreamly.inCoreAoS sPUMSRunningCount
  K.logLE K.Info $ "frame has " <> show (FL.fold FL.length fPums'') <> " rows."
  K.logLE K.Info $ "toS and fromS transform and load that stream to frame..."
  let sPUMSRCToS = Streamly.map FS.toS sPUMSRunningCount
  K.logLE K.Info $ "testing Memory.Array (fold to raw bytes)"

  K.logLE K.Info $ "v1 (cereal, bsb)"
--    sDict  = KS.cerealStreamlyDict
  serializedBytes :: KS.DefaultCacheData  <- K.streamlyToKnit
                                             $ Streamly.fold (streamlySerializeF2 @S.Serialize encodeBSB bsbToCT)  sPUMSRCToS
  print $ Streamly.Memory.Array.length serializedBytes

  K.logLE K.Info $ "v1 (cereal, bs)"
--    sDict  = KS.cerealStreamlyDict
  serializedBytes' :: KS.DefaultCacheData  <- K.streamlyToKnit
                                              $ Streamly.fold (streamlySerializeF2 @S.Serialize encodeOne bldrToCT)  sPUMSRCToS
  print $ Streamly.Memory.Array.length serializedBytes'

{-
  K.logLE K.Info $ "v1 (binary)"
--    sDict  = KS.cerealStreamlyDict
  bSerializedBytes :: KS.DefaultCacheData  <- K.streamlyToKnit
                                             $ Streamly.fold (streamlySerializeF2 @B.Binary bEncodeBSB bsbToCT)  sPUMSRCToS


  print $ Streamly.Memory.Array.length bSerializedBytes


  K.logLE K.Info $ "v2 (cereal)"
  let bldrStream = Streamly.map encodeBSB sPUMSRCToS
  n <- K.streamlyToKnit $ Streamly.length bldrStream
  fullBldr <- K.streamlyToKnit $ Streamly.foldl' (<>) mempty bldrStream
  let serializedBytes2 = toCT fullBldr n
  print $ Streamly.Memory.Array.length serializedBytes2

  K.logLE K.Info $ "v3 (cereal)"
--  let bldrStream3 = Streamly.map encodeBS sPUMSRCToS
  let assemble :: Int -> BS.ByteString -> BS.ByteString
      assemble n bs = encodeBS (fromIntegral @Int @Word.Word64 n) <> bs
      fSB :: Streamly.Fold.Fold K.StreamlyM ByteString ByteString
      fSB = assemble <$> Streamly.Fold.length <*> Streamly.Fold.mconcat
      bldrStream2 :: Streamly.SerialT K.StreamlyM ByteString = Streamly.map encodeBS sPUMSRCToS

  serializedBytes3 <- K.streamlyToKnit $ Streamly.fold fSB bldrStream2
  print $ BS.length serializedBytes3

  K.logLE K.Info $ "v3 (binary)"
--  let bldrStream3 = Streamly.map encodeBS sPUMSRCToS
  let bAssemble :: Int -> BS.ByteString -> BS.ByteString
      bAssemble n bs = bEncodeBS (fromIntegral @Int @Word.Word64 n) <> bs
      bfSB :: Streamly.Fold.Fold K.StreamlyM ByteString ByteString
      bfSB = bAssemble <$> Streamly.Fold.length <*> Streamly.Fold.mconcat
      bbldrStream2 :: Streamly.SerialT K.StreamlyM ByteString = Streamly.map bEncodeBS sPUMSRCToS

  bSerializedBytes3 <- K.streamlyToKnit $ Streamly.fold bfSB bbldrStream2
  print $ BS.length bSerializedBytes3


  K.logLE K.Info "v4 (cereal)"
  serializedBytes4 <- BSB.builderBytes
                      <$> (K.streamlyToKnit $ Streamly.foldl' (\acc x -> let b = S.runPut (S.put x) in seq b (acc <> BSB.bytes b)) mempty sPUMSRCToS)
  print $ BS.length serializedBytes4

-}



{-

  K.logLE K.Info "Testing typedPUMSRowsLoader..."
  BR.clearIfPresentD "data/testbed/acs1YR_All_Typed.bin"
  cfPUMSRaw <- PUMS.typedPUMSRowsLoader' dataPath (Just "testbed/acs1YR_All_Typed.bin")
  fPUMSRaw <- K.ignoreCacheTime cfPUMSRaw
  let nRaw = FL.fold FL.length fPUMSRaw
  K.logLE K.Info $ "PUMS data has " <> show nRaw <> " rows."

  K.logLE K.Info "Testing pumsRowsLoader..."
  BR.clearIfPresentD "data/testbed/acs1YR_Small.bin"
  cfPUMSSmall <- PUMS.pumsRowsLoader' dataPath (Just "testbed/acs1YR_Small.bin") Nothing
  fPUMSSmall <- K.ignoreCacheTime cfPUMSSmall
  let nSmall = FL.fold FL.length fPUMSSmall
  K.logLE K.Info $ "PUMS data has " <> show nSmall <> " rows."
-}
{-
  K.logLE K.Info "Testing pumsLoader bits... (including MR fold)"
  K.logLE K.Info "count fold (usual)"
  let fPUMS = FL.fold PUMS.pumsCountF fPUMSSmall --dataPath (Just "testbed/acs1YR_Small.bin") "testbed/acs1YR_folded.bin" Nothing
  let nPUMS = FL.fold FL.length fPUMS
  K.logLE K.Info $ "folded PUMS data has " <> show nPUMS <> " rows."
-}
{-
  K.logLE K.Info "count fold (framesStreamlyMR)"
  fPUMS2 <- K.streamlyToKnit $ FL.foldM PUMS.pumsCountStreamlyF fPUMSSmall
  let nPUMS2 = FL.fold FL.length fPUMS2
  K.logLE K.Info $ "streamlyMR folded PUMS data has " <> show nPUMS2 <> " rows."

  K.logLE K.Info "count fold (framesStreamlyMRM_SF)"
  fPUMS3 <- K.streamlyToKnit $ PUMS.pumsCountStreamly fPUMSSmall
  let nPUMS3 = FL.fold FL.length fPUMS3
  K.logLE K.Info $ "streamlyMR folded PUMS data has " <> show nPUMS3 <> " rows."

  K.logLE K.Info "count fold (fStreamlyMRM_HT)"
  fPUMS4 <- K.streamlyToKnit $ PUMS.pumsCountStreamlyHT fPUMSSmall
  let nPUMS4 = FL.fold FL.length fPUMS4
  K.logLE K.Info $ "streamlyMR folded PUMS data has " <> show nPUMS4 <> " rows."
-}
{-
  K.logLE K.Info "count fold (direct 1)"
  fMap <- K.streamlyToKnit

          $ fmap ({- Streamly.fromFoldable .-} M.mapWithKey V.rappend)
          $ fmap (fmap (FL.fold PUMS.pumsRowCountF))
          $ Streamly.fold (Streamly.Fold.classify FStreamly.inCoreAoS_F)
          $ Streamly.map (\x -> (F.rcast @(PUMS.PUMADesc V.++ PUMS.PUMABucket) x, F.rcast @PUMS.PUMSCountFromFields x))
          $ Streamly.fromFoldable fPUMSSmall
  let nMap = FL.fold FL.length fMap
  K.logLE K.Info $ "streamlyMR map has " <> show nMap <> " rows."
-}
{-
  K.logLE K.Info "count fold (direct 2)"
  fPUMS2 <- K.streamlyToKnit
--            $ FStreamly.inCoreAoS
--            $ Streamly.concatM
            $ fmap (F.toFrame . M.mapWithKey V.rappend)
            $ Streamly.fold (Streamly.Fold.classify $ toStreamlyFold PUMS.pumsRowCountF)
            $ Streamly.map (\x -> (F.rcast @(PUMS.PUMADesc V.++ PUMS.PUMABucket) x, F.rcast @PUMS.PUMSCountFromFields x))
            $ Streamly.fromFoldable fPUMSSmall
  let nPUMS2 = FL.fold FL.length fPUMS2
  K.logLE K.Info $ "streamlyMR (direct) has " <> show nPUMS2 <> " rows."
  K.logLE K.Info $ show $ T.intercalate "\n" $ fmap show $ FL.fold FL.list fPUMS2
-}
{-
  K.logLE K.Info "count fold (direct 3)"
  fPUMS3 <- K.streamlyToKnit
            $ BRF.frameCompactMRM
            FMR.noUnpack
            (FMR.assignKeysAndData @(PUMS.PUMADesc V.++ PUMS.PUMABucket) @PUMS.PUMSCountFromFields)
             PUMS.pumsRowCountF
            fPUMSSmall
  let nPUMS3 = FL.fold FL.length fPUMS3
  K.logLE K.Info $ "streamlyMR (direct from Framesutils) has " <> show nPUMS3 <> " rows."
  K.logLE K.Info $ show $ T.intercalate "\n" $ fmap show $ FL.fold FL.list fPUMS3

  K.logLE K.Info "Testing pumsLoader..."
  BR.clearIfPresentD (T.pack "test/ACS_1YR.sbin")
  BR.clearIfPresentD (T.pack "data/test/ACS_1YR_Raw.sbin")
  pumsAge5F_C <- PUMS.pumsLoader' dataPath (Just "test/ACS_1YR_Raw.sbin") "test/ACS_1YR.sbin" Nothing
  pumsAge5F <- K.ignoreCacheTime pumsAge5F_C
  K.logLE K.Info $ "PUMS data has " <> (T.pack $ show $ FL.fold FL.length pumsAge5F) <> " rows."
-}


--  if fMap == fMap2
--    then K.logLE K.Info "Maps are the same"
--    else K.logLE K.Info "Maps are *not* the same"

{-

  K.logLE K.Info $ "v2"
  let bldrStream = Streamly.map encodeBSB sPUMSRCToS
  n <- K.streamlyToKnit $ Streamly.length bldrStream
  fullBldr <- K.streamlyToKnit $ Streamly.foldl' (<>) mempty bldrStream
  let serializedBytes2 = toCT fullBldr n
  print $ Streamly.Memory.Array.length serializedBytes2

  let testCacheKey = "test/fPumsCached.sbin"
-}
{-
  K.logLE K.Info $ "v3"
--  let bldrStream3 = Streamly.map encodeBS sPUMSRCToS
  let assemble :: Int -> BS.ByteString -> BS.ByteString
      assemble n bs = encodeBS (fromIntegral @Int @Word.Word64 n) <> bs
      fSB :: Streamly.Fold.Fold K.StreamlyM ByteString ByteString
      fSB = assemble <$> Streamly.Fold.length <*> Streamly.Fold.mconcat
      bldrStream2 :: Streamly.SerialT K.StreamlyM ByteString = Streamly.map encodeBS sPUMSRCToS

  serializedBytes3 <- K.streamlyToKnit $ Streamly.fold fSB bldrStream2
  print $ BS.length serializedBytes3
-}
{-
  K.logLE K.Info "v4"
  serializedBytes4 <- BSB.builderBytes
                      <$> (K.streamlyToKnit $ Streamly.foldl' (\acc x -> let b = S.runPut (S.put x) in seq b (acc <> BSB.bytes b)) mempty sPUMSRCToS)
  print $ BS.length serializedBytes4
-}
{-
  K.logLE K.Info $ "v4"
--    sDict  = KS.cerealStreamlyDict
  lazyList <- K.streamlyToKnit $ Streamly.toList bldrStream
  let n2 = length lazyList
      bb = mconcat $ encodeBSB (fromIntegral @Int @Word.Word64 n2) : lazyList
      serializedBytes4 =  Streamly.ByteString.toArray $ BSB.builderBytes bb
  print $ Streamly.Memory.Array.length serializedBytes4
-}
  {-
  K.logLE K.Info "test array "
  K.streamlyToKnit $ do
    arr <- Streamly.fold Streamly.Data.Array.write sPUMSRunningCount
    print $ Streamly.Data.Array.length arr
-}
{-
  let --bufferFold = fmap Streamly.Data.Array.toStream Streamly.Data.Array.write
      buffer :: Streamly.SerialT K.StreamlyM a -> K.StreamlyM (Streamly.SerialT K.StreamlyM a)
      buffer = fmap (Streamly.unfold Streamly.Data.Array.read) . Streamly.fold Streamly.Data.Array.write
  sBuffered :: Streamly.SerialT K.StreamlyM (F.Record PUMS.PUMS_Typed) <- K.streamlyToKnit
                                                                          $ buffer sPUMSRunningCount
  bufferRows <- K.streamlyToKnit $ Streamly.length sBuffered
  K.logLE K.Info $ "buffer stream is " <> show bufferRows <> " bytes long"
-}
  {-
  BR.clearIfPresentD testCacheKey
  K.logLE K.Info $ "retrieveOrMake (action)"
  awctPUMSRunningCount2 <- KAC.retrieveOrMake @KS.DefaultCacheData  (KC.knitSerializeStream sDict) testCacheKey (pure ())
                           $ const
                           $ return sPUMSRCToS
  swctPUMSRunningCount2 <- K.ignoreCacheTime awctPUMSRunningCount2
  --sPUMSRunningCount2 <- K.ignoreCacheTime csPUMSRunningCount
  iRows2 <-  K.streamlyToKnit $ Streamly.fold Streamly.Fold.length swctPUMSRunningCount2
  K.logLE K.Info $ "raw PUMS data has " <> (T.pack $ show iRows2) <> " rows."
-}

{-
  K.logLE K.Info "Testing pumsRowsLoader..."
  let pumsRowsFixedS = PUMS.pumsRowsLoader dataPath Nothing
  fixedRows <- K.streamlyToKnit $ Streamly.fold Streamly.Fold.length pumsRowsFixedS
  K.logLE K.Info $ "fixed PUMS data has " <> (T.pack $ show fixedRows) <> " rows."

  K.logLE K.Info "Testing pumsLoader..."
  BR.clearIfPresentD (T.pack "test/ACS_1YR.sbin")
  BR.clearIfPresentD (T.pack "data/test/ACS_1YR_Raw.sbin")
  pumsAge5F_C <- PUMS.pumsLoader' dataPath (Just "test/ACS_1YR_Raw.sbin") "test/ACS_1YR.sbin" Nothing
  pumsAge5F <- K.ignoreCacheTime pumsAge5F_C
  K.logLE K.Info $ "PUMS data has " <> (T.pack $ show $ FL.fold FL.length pumsAge5F) <> " rows."
-}

  K.logLE K.Info "done"


testInIO :: IO ()
testInIO = do
  let pumsCSV = "../bigData/test/acs100k.csv"
      dataPath = (Loaders.LocalData $ T.pack $ pumsCSV)
  putTextLn "Testing File.toBytes..."
  let rawBytesS =  Streamly.File.toBytes pumsCSV
  rawBytes <-  Streamly.fold Streamly.Fold.length rawBytesS
  putTextLn $ "raw PUMS data has " <> show rawBytes <> " bytes."
  putTextLn "Testing readTable..."
  let sPUMSRawRows :: Streamly.SerialT IO PUMS.PUMS_Raw2
        = FStreamly.readTableOpt Frames.defaultParser pumsCSV
  iRows <-  Streamly.fold Streamly.Fold.length sPUMSRawRows
  putTextLn $ "raw PUMS data has " <> (T.pack $ show iRows) <> " rows."
  putTextLn "Testing Frames.Streamly.inCoreAoS:"
  fPums <- FStreamly.inCoreAoS sPUMSRawRows
  putTextLn $ "raw PUMS frame has " <> show (FL.fold FL.length fPums) <> " rows."
  -- Previous goes up to 28MB, looks like via doubling.  Then to 0 (collects fPums after counting?)
  -- This one then climbs to 10MB, rows are smaller.  No large leaks.
  let f !x = PUMS.transformPUMSRow' x
  putTextLn "Testing Frames.Streamly.inCoreAoS with row transform:"
  fPums' <- FStreamly.inCoreAoS $ Streamly.map f sPUMSRawRows
  putTextLn $ "transformed PUMS frame has " <> show (FL.fold FL.length fPums') <> " rows."
  putTextLn "v1"
--    sDict  = KS.cerealStreamlyDict
  let countFold = Loaders.runningCountF "reading..." (\n -> "read " <> show (250000 * n) <> " rows") "finished"
      sPUMSRunningCount = Streamly.map PUMS.transformPUMSRow'
                          $ Streamly.tapOffsetEvery 250000 250000 countFold sPUMSRawRows
      sPUMSRCToS = Streamly.map FS.toS sPUMSRunningCount

  serializedBytes :: KS.DefaultCacheData  <- Streamly.fold (streamlySerializeF2 @S.Serialize encodeBSB bsbToCT)  sPUMSRCToS
  print $ Streamly.Memory.Array.length serializedBytes

  putTextLn "v4"
  bldr <- Streamly.foldl' (\acc !x -> let b = S.runPut (S.put x) in b `seq` (acc <> BSB.bytes b)) mempty sPUMSRCToS
  print $ BS.length $ BSB.builderBytes bldr


{-
  putTextLn "v5"
  bldr <- Streamly.foldl' (\acc !x -> let b = encodeOne x in b `seq` (acc <> b)) mempty sPUMSRCToS
  print $ BS.length $ BL.toStrict $ BB.toLazyByteString bldr
-}

  return ()

{-
testsInIO :: IO ()
testsInIO = do
  let pumsCSV = "testbed/medPUMS.csv"
  putStrLn "Tests in IO"
  putStrLn $ T.unpack "Testing File.toBytes..."
  let rawBytesS = Streamly.File.toBytes pumsCSV
  rawBytes <- Streamly.fold Streamly.Fold.length rawBytesS
  putStrLn $ T.unpack $ "raw PUMS data has " <> (T.pack $ show rawBytes) <> " bytes."
  putStrLn $ T.unpack "Testing streamTable..."
  let pumsRowsRawS :: Streamly.SerialT IO PUMS.PUMS_Raw
        = FStreamly.readTableOpt Frames.defaultParser pumsCSV
  rawRows <- Streamly.fold Streamly.Fold.length pumsRowsRawS
  putStrLn $ T.unpack $ "raw PUMS data has " <> (T.pack $ show rawRows) <> " rows."
  let --pumsRowsFixedS :: Streamly.SerialT IO PUMS.PUMS
      pumsRowsFixedS = Loaders.recStreamLoader (Loaders.LocalData $ T.pack $ pumsCSV) Nothing Nothing PUMS.transformPUMSRow
  fixedRows <- Streamly.fold Streamly.Fold.length pumsRowsFixedS
  putStrLn $ T.unpack $ "fixed PUMS data has " <> (T.pack $ show fixedRows) <> " rows."
-}
