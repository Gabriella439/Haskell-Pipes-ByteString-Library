{-| This module provides @pipes@ utilities for \"byte streams\", which are
    streams of strict 'BS.ByteString's chunks.  Use byte streams to interact
    with both 'Handle's and lazy 'ByteString's.

    To stream from 'Handle's, use 'readHandleS' or 'writeHandleD' to convert
    them into the equivalent proxies.  For example, the following program copies
    data from one file to another:

> import Control.Proxy
> import Control.Proxy.ByteString
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runProxy $ readHandleS hIn >-> writeHandleD hOut

    You can also stream to and from 'stdin' and 'stdout' using the predefined
    'stdinS' and 'stdoutD' proxies, like in the following \"echo\" program:

> main = runProxy $ stdinS >-> stdoutD

    You can also translate pure lazy 'BL.ByteString's to and from proxies:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runProxy $ fromLazyS (BL.pack "Hello, world!\n") >-> stdoutD

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform byte streams.
-}

module Control.Proxy.ByteString (
    -- * Introducing and Eliminating ByteStrings
    fromLazyS,
    toLazyD,

    -- * Basic Interface
    headD,
    headD_,
    lastD,
    tailD,
    initD,
    nullD,
    nullD_,
    lengthD,

    -- * Transforming ByteStrings
    mapD,
    intersperseD,

    -- * Reducing ByteStrings (folds)
    foldlD',
    foldrD,

    -- ** Special folds
    concatMapD,
    anyD,
    anyD_,
    allD,
    allD_,

    -- * Substrings
    -- ** Breaking strings
    takeD,
    dropD,
    takeWhileD,
    dropWhileD,
    groupD,
    groupByD,

    -- ** Breaking into many substrings
    splitD,
    splitWithD,

    -- * Searching ByteStrings
    -- ** Searching by equality
    elemD,
    elemD_,
    notElemD,

    -- ** Searching with a predicate
    findD,
    findD_,
    filterD,

    -- * Indexing ByteStrings
    indexD,
    indexD_,
    elemIndexD,
    elemIndexD_,
    elemIndicesD,
    findIndexD,
    findIndexD_,
    findIndicesD,
    countD,

    -- * I/O with ByteStrings
    -- ** Standard input and output
    stdinS,
    stdoutD,

    -- ** I/O with Handles
    readHandleS,
    writeHandleD,
    hGetSomeS,
    hGetSomeS_,
    hGetS,
    hGetS_,

    -- * Parsers
    isEndOfBytes,
    drawAllBytes,
    passBytesUpTo,
    ) where

import Control.Monad (forever)
import Control.Monad.Trans.Class (lift)
import qualified Control.Proxy as P
import Control.Proxy.Parse (draw, unDraw, drawAll)
import Control.Proxy.Trans.State (StateP(StateP))
import Control.Proxy.Trans.Writer (WriterP, tell)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Unsafe as BU
import Data.Foldable (forM_)
import qualified Data.Monoid as M
import Data.Int (Int64)
import Data.Word (Word8)
import System.IO (Handle, hIsEOF, stdin, stdout)

{-| Convert a lazy 'BL.ByteString' into a 'P.Producer' of strict
    'BS.ByteString's

> fromLazyS
>  :: (Monad m, Proxy p)
>  => Lazy.ByteString -> () -> Producer p Strict.ByteString m ()
-}
fromLazyS
    :: (Monad m, P.Proxy p) => BL.ByteString -> r -> p x' x y' BS.ByteString m r
fromLazyS bs r =
    P.runIdentityP $ BLI.foldrChunks (\e a -> P.respond e >> a) (return r) bs

{-| Fold strict 'BS.ByteString's flowing \'@D@\'ownstream into a lazy
    'BL.ByteString'.

    The fold generates a difference 'BL.ByteString' that you must apply to
    'BS.empty'.

> toLazyD
>     :: (Monad m, P.Proxy p)
>     => () -> Pipe (WriterP (Endo Lazy.ByteString)) p Strict.ByteString Strict.ByteString m r
-}
toLazyD
    :: (Monad m, P.Proxy p)
    => x -> WriterP (M.Endo BL.ByteString) p x BS.ByteString x BS.ByteString m r
toLazyD = P.foldrD BLI.Chunk

-- | Store the 'M.First' 'Word8' that flows \'@D@\'ownstream
headD
    :: (Monad m, P.Proxy p)
    => x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m r
headD = P.foldD (\bs -> M.First $
    if (BS.null bs)
        then Nothing
        else Just $ BU.unsafeHead bs )

{-| Store the 'M.First' 'Word8' that flows \'@D@\'ownstream

    Terminates after receiving a single 'Word8'. -}
headD_
    :: (Monad m, P.Proxy p)
    => x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m ()
headD_ = go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else tell . M.First . Just $ BU.unsafeHead bs

-- | Store the 'M.Last' 'Word8' that flows \'@D@\'ownstream
lastD
    :: (Monad m, P.Proxy p)
    => x -> WriterP (M.Last Word8) p x BS.ByteString x BS.ByteString m r
lastD = P.foldD (\bs -> M.Last $
    if (BS.null bs)
        then Nothing
        else Just $ BS.last bs )

-- | Drop the first byte in the stream
tailD :: (Monad m, P.Proxy p) => x -> p x BS.ByteString x BS.ByteString m r
tailD = P.runIdentityK go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else do
                x2 <- P.respond (BU.unsafeTail bs)
                P.pull x2

-- | Pass along all but the last byte in the stream
initD :: (Monad m, P.Proxy p) => x -> p x BS.ByteString x BS.ByteString m r
initD = P.runIdentityK go0 where
    go0 x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go0 x2
            else do
                x2 <- P.respond (BS.init bs)
                go1 (BS.last bs) x2
    go1 w8 x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go1 w8 x2
            else do
                x2 <- P.respond (BS.cons w8 (BS.init bs))
                go1 (BS.last bs) x2

-- | Store whether 'M.All' received 'ByteString's are empty
nullD
    :: (Monad m, P.Proxy p)
    => x -> WriterP M.All p x BS.ByteString x BS.ByteString m r
nullD = P.foldD (M.All . BS.null)

{-| Store whether 'M.All' received 'ByteString's are empty

    'nullD_' terminates on the first non-empty 'ByteString'. -}
nullD_
    :: (Monad m, P.Proxy p)
    => x -> WriterP M.All p x BS.ByteString x BS.ByteString m ()
nullD_ = go where
    go x = do
        bs <- P.request x
        if (BS.null bs)
            then do
                x2 <- P.respond bs
                go x2
            else tell (M.All False)

-- | Store the length of all input flowing \'@D@\'ownstream
lengthD
    :: (Monad m, P.Proxy p)
    => x -> WriterP (M.Sum Int) p x BS.ByteString x BS.ByteString m r
lengthD = P.foldD (M.Sum . BS.length)

-- | Apply a transformation to each 'Word8' in the stream
mapD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Word8) -> x -> p x BS.ByteString x BS.ByteString m r
mapD f = P.mapD (BS.map f)

-- | Intersperse a 'Word8' between each byte in the stream
intersperseD
    :: (Monad m, P.Proxy p)
    => Word8 -> x -> p x BS.ByteString x BS.ByteString m r
intersperseD w8 = P.runIdentityK go0 where
    go0 x = do
        bs0 <- P.request x
        x2  <- P.respond (BS.intersperse w8 bs0)
        go1 x2
    go1 x = do
        bs <- P.request x
        x2 <- P.respond (BS.cons w8 (BS.intersperse w8 bs))
        go1 x2

-- | Reduce the stream of bytes using a strict left fold
foldlD'
    :: (Monad m, P.Proxy p)
    => (s -> Word8 -> s) -> x -> StateP s p x BS.ByteString x BS.ByteString m r
foldlD' f = go where
    go x = do
        bs <- P.request x
        StateP (\s -> let s' = BS.foldl' f s bs
                      in  s' `seq` P.return_P ((), s'))
        x2 <- P.respond bs
	go x2

-- | Reduce the stream of bytes using a right fold
foldrD
    :: (Monad m, P.Proxy p)
    => (Word8 -> w -> w)
    -> x -> WriterP (M.Endo w) p x BS.ByteString x BS.ByteString m r
foldrD f = P.foldrD (\e w -> BS.foldr f w e)

-- | Map a function over the byte stream and concatenate the results
concatMapD
    :: (Monad m, P.Proxy p)
    => (Word8 -> BS.ByteString) -> x -> p x BS.ByteString x BS.ByteString m r
concatMapD f = P.mapD (BS.concatMap f)

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
anyD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP M.Any p x BS.ByteString x BS.ByteString m r
anyD pred = P.foldD (M.Any . BS.any pred)

{-| Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate

    'anyD_' terminates on the first 'Word8' that satisfies the predicate. -}
anyD_
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP M.Any p x BS.ByteString x BS.ByteString m ()
anyD_ pred = go where
    go x = do
        bs <- P.request x
        if (BS.any pred bs)
            then tell (M.Any True)
            else do
                x2 <- P.respond bs
                go x2

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
allD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP M.All p x BS.ByteString x BS.ByteString m r
allD pred = P.foldD (M.All . BS.all pred)

{-| Fold that returns whether 'M.All' received 'Word8's satisfy the predicate

    'allD_' terminates on the first 'Word8' that fails the predicate. -}
allD_
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP M.All p x BS.ByteString x BS.ByteString m ()
allD_ pred = go where
    go x = do
        bs <- P.request x
        if (BS.all pred bs)
            then do
                x2 <- P.respond bs
                go x2
            else tell (M.All False)

{-
newtype Maximum a = Maximum { getMaximum :: Maybe a }

instance (Ord a) => Monoid (Maximum a) where
    mempty = Maximum Nothing
    mappend m1 (Maximum Nothing) = m1
    mappend (Maximum Nothing) m2 = m2
    mappend (Maximum (Just a1)) (Maximum (Just a2)) = Maximum (Just (max a1 a2))

maximumD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Maximum Word8) m) r
maximumD = P.foldD (\bs -> Maximum $
    if (BS.null bs)
        then Nothing
        else Just $ BS.maximum bs )

newtype Minimum a = Minimum { getMinimum :: Maybe a }

instance (Ord a) => Monoid (Minimum a) where
    mempty = Minimum Nothing
    mappend m1 (Minimum Nothing) = m1
    mappend (Minimum Nothing) m2 = m2
    mappend (Minimum (Just a1)) (Minimum (Just a2)) = Minimum (Just (min a1 a2))

minimumD
 :: (Monad m, P.Proxy p)
 => x -> p x BS.ByteString x BS.ByteString (WriterT (Minimum Word8) m) r
minimumD = P.foldD (\bs -> Minimum $
    if (BS.null bs)
        then Nothing
        else Just $ BS.minimum bs )
-}

-- | @(takeD n)@ only allows @n@ bytes to flow \'@D@\'ownstream
takeD
    :: (Monad m, P.Proxy p)
    => Int64 -> x -> p x BS.ByteString x BS.ByteString m ()
takeD n0 = P.runIdentityK (go n0) where
    go n
        | n <= 0 = \_ -> return ()
        | otherwise = \x -> do
            bs <- P.request x
            let len = fromIntegral $ BS.length bs
            if (len > n)
                then do
                    P.respond (BU.unsafeTake (fromIntegral n) bs)
                    return ()
                else do
                    x2 <- P.respond bs
                    go (n - len) x2

-- | @(dropD n)@ drops the first @n@ bytes flowing \'@D@\'ownstream
dropD
    :: (Monad m, P.Proxy p)
    => Int64 -> () -> P.Pipe p BS.ByteString BS.ByteString m r
dropD n0 () = P.runIdentityP (go n0) where
    go n
        | n <= 0 = P.pull ()
        | otherwise = do
            bs <- P.request ()
            let len = fromIntegral $ BS.length bs
            if (len >= n)
                then do
                    P.respond (BU.unsafeDrop (fromIntegral n) bs)
                    P.pull ()
                else go (n - len)

-- | Take bytes until they fail the predicate
takeWhileD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool) -> x -> p x BS.ByteString x BS.ByteString m ()
takeWhileD pred = P.runIdentityK go where
    go x = do
        bs <- P.request x
        case BS.findIndex (not . pred) bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just i -> do
                P.respond (BU.unsafeTake i bs)
                return ()

-- | Drop bytes until they fail the predicate
dropWhileD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool) -> () -> P.Pipe p BS.ByteString BS.ByteString m r
dropWhileD pred () = P.runIdentityP go where
    go = do
        bs <- P.request ()
        case BS.findIndex (not . pred) bs of
            Nothing -> go
            Just i -> do
                P.respond (BU.unsafeDrop i bs)
                P.pull ()

-- | Group 'Nothing'-delimited streams of bytes into segments of equal bytes
groupD
    :: (Monad m, P.Proxy p)
    => () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
groupD = groupByD (==)

{-| Group 'Nothing'-delimited streams of bytes using the supplied equality
    function -}
groupByD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Word8 -> Bool)
    -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
groupByD eq () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs
                | BS.null bs -> go1
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    mapM_ P.respond (init groups)
                    go2 (last groups)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs
                | BS.null bs -> go2 group0
                | otherwise -> do
                    let groups = BS.groupBy eq bs
                    case groups of
                        []              -> go2 group0
                        [group1]        -> go2 (BS.append group0 group1)
                        gs@(group1:gs') -> do
                            if (BS.head group0 == BS.head group1)
                                then do
                                    P.respond (BS.append group0 group1)
                                    mapM_ P.respond (init gs')
                                    go2 (last gs')
                                else do
                                    P.respond group0
                                    mapM_ P.respond (init gs )
                                    go2 (last gs )

-- | Split 'Nothing'-delimited streams of bytes using the given 'Word8' boundary
splitD
    :: (Monad m, P.Proxy p)
    => Word8 -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
splitD w8 = splitWithD (w8 ==)

{-| Split 'Nothing'-delimited streams of bytes using the given predicate to
    define boundaries -}
splitWithD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool) -> () -> P.Pipe p (Maybe BS.ByteString) BS.ByteString m r
splitWithD pred () = P.runIdentityP go1 where
    go1 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> go1
            Just bs -> case BS.splitWith pred bs of
                [] -> go1
                gs -> do
                    mapM_ P.respond (init gs)
                    go2 (last gs)
    go2 group0 = do
        mbs <- P.request ()
        case mbs of
            Nothing -> do
                P.respond group0
                go1
            Just bs -> case BS.splitWith pred bs of
                []        -> go2 group0
                [group1]  -> go2 (BS.append group0 group1)
                group1:gs -> do
                    P.respond (BS.append group0 group1)
                    mapM_ P.respond (init gs)
                    go2 (last gs)

-- | Store whether 'M.Any' element in the byte stream matches the given 'Word8'
elemD
    :: (Monad m, P.Proxy p)
    => Word8 -> x -> WriterP M.Any p x BS.ByteString x BS.ByteString m r
elemD w8 = P.foldD (M.Any . BS.elem w8)

{-| Store whether 'M.Any' element in the byte stream matches the given 'Word8'

    'elemD_' terminates once a single 'Word8' matches the predicate. -}
elemD_
    :: (Monad m, P.Proxy p)
    => Word8 -> x -> WriterP M.Any p x BS.ByteString x BS.ByteString m ()
elemD_ w8 = go where
    go x = do
        bs <- P.request x
        if (BS.elem w8 bs)
            then tell (M.Any True)
            else do
                x2 <- P.respond bs
                go x2

{-| Store whether 'M.All' elements in the byte stream do not match the given
    'Word8' -}
notElemD
    :: (Monad m, P.Proxy p)
    => Word8 -> x -> WriterP M.All p x BS.ByteString x BS.ByteString m r
notElemD w8 = P.foldD (M.All . BS.notElem w8)

-- | Store the 'M.First' element in the stream that matches the predicate
findD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m r
findD pred = P.foldD (M.First . BS.find pred)

{-| Store the 'M.First' element in the stream that matches the predicate

    'findD_' terminates when a 'Word8' matches the predicate -}
findD_
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m ()
findD_ pred = go where
    go x = do
        bs <- P.request x
        case BS.find pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go x2
            Just w8 -> tell . M.First $ Just w8

-- | Only allows 'Word8's to pass if they satisfy the predicate
filterD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool) -> x -> p x BS.ByteString x BS.ByteString m r
filterD pred = P.mapD (BS.filter pred)

-- | Stores the element located at a given index, starting from 0
indexD
    :: (Monad m, P.Proxy p)
    => Int64
    -> x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m r
indexD n = go n where
    go n x = do
        bs <- P.request x
        let len = fromIntegral $ BS.length bs
        if (len <= n)
            then do
                x2 <- P.respond bs
                go (n - len) x2
            else do
                tell . M.First . Just . BS.index bs $ fromIntegral n
                x2 <- P.respond bs
                P.pull x2

{-| Stores the element located at a given index, starting from 0

    'indexD_' terminates once it reaches the given index. -}
indexD_
    :: (Monad m, P.Proxy p)
    => Int64
    -> x -> WriterP (M.First Word8) p x BS.ByteString x BS.ByteString m ()
indexD_ n = go n where
    go n x = do
        bs <- P.request x
        let len = fromIntegral $ BS.length bs
        if (len <= n)
            then do
                x2 <- P.respond bs
                go (n - len) x2
            else tell . M.First . Just . BS.index bs $ fromIntegral n

-- | Stores the 'M.First' index of an element that matches the given 'Word8'
elemIndexD
    :: (Monad m, P.Proxy p)
    => Word8
    -> x -> WriterP (M.First Int64) p x BS.ByteString x BS.ByteString m r
elemIndexD w8 = go 0 where
    go n x = do
        bs <- P.request x
        case BS.elemIndex w8 bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> do
                tell . M.First . Just $ n + fromIntegral i
                x2 <- P.respond bs
                P.pull x2

{-| Stores the 'M.First' index of an element that matches the given 'Word8'

    'elemIndexD_' terminates when it encounters a matching 'Word8' -}
elemIndexD_
    :: (Monad m, P.Proxy p)
    => Word8
    -> x -> WriterP (M.First Int64) p x BS.ByteString x BS.ByteString m ()
elemIndexD_ w8 = go 0 where
    go n x = do
        bs <- P.request x
        case BS.elemIndex w8 bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> tell . M.First . Just $ n + fromIntegral i

-- | Store a list of all indices whose elements match the given 'Word8'
elemIndicesD
    :: (Monad m, P.Proxy p)
    => Word8
    -> x -> WriterP [Int64] p x BS.ByteString x BS.ByteString m r
elemIndicesD w8 = P.foldD (map fromIntegral . BS.elemIndices w8)

-- | Store the 'M.First' index of an element that satisfies the predicate
findIndexD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP (M.First Int64) p x BS.ByteString x BS.ByteString m r
findIndexD pred = go 0 where
    go n x = do
        bs <- P.request x
        case BS.findIndex pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> do
                tell . M.First . Just $ n + fromIntegral i
                x2 <- P.respond bs
                P.pull x2

{-| Store the 'M.First' index of an element that satisfies the predicate

    'findIndexD_' terminates when an element satisfies the predicate -}
findIndexD_
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP (M.First Int64) p x BS.ByteString x BS.ByteString m ()
findIndexD_ pred = go 0 where
    go n x = do
        bs <- P.request x
        case BS.findIndex pred bs of
            Nothing -> do
                x2 <- P.respond bs
                go (n + fromIntegral (BS.length bs)) x2
            Just i  -> tell . M.First . Just $ n + fromIntegral i

-- | Store a list of all indices whose elements satisfy the given predicate
findIndicesD
    :: (Monad m, P.Proxy p)
    => (Word8 -> Bool)
    -> x -> WriterP [Int64] p x BS.ByteString x BS.ByteString m r
findIndicesD pred = go 0 where
    go n x = do
        bs <- P.request x
        tell . map (\i -> n + fromIntegral i) $ BS.findIndices pred bs
        x2 <- P.respond bs
        go (n + fromIntegral (BS.length bs)) x2

-- | Store a tally of how many elements match the given 'Word8'
countD
    :: (Monad m, P.Proxy p)
    => Word8 -> x -> WriterP (M.Sum Int64) p x BS.ByteString x BS.ByteString m r
countD w8 = P.foldD (M.Sum . fromIntegral . BS.count w8)

-- | Stream bytes from 'stdin'
stdinS :: (P.Proxy p) => () -> P.Producer p BS.ByteString IO ()
stdinS = readHandleS stdin

-- | Stream bytes to 'stdout'
stdoutD :: (P.Proxy p) => x -> p x BS.ByteString x BS.ByteString IO ()
stdoutD = writeHandleD stdout

-- | Convert a 'Handle' into a byte stream
readHandleS :: (P.Proxy p) => Handle -> () -> P.Producer p BS.ByteString IO ()
readHandleS = hGetSomeS BLI.defaultChunkSize

-- | Convert a byte stream into a 'Handle'
writeHandleD
    :: (P.Proxy p) => Handle -> x -> p x BS.ByteString x BS.ByteString IO r
writeHandleD h = P.useD (BS.hPut h)

-- | Convert a handle into a byte stream using a fixed chunk size
hGetSomeS
    :: (P.Proxy p) => Int -> Handle -> () -> P.Producer p BS.ByteString IO ()
hGetSomeS size h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGetSome h size
                P.respond bs
                go

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetSomeS_ :: (P.Proxy p) => Handle -> Int -> P.Server p Int BS.ByteString IO ()
hGetSomeS_ h = P.runIdentityK go where
    go size = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGetSome h size
                size2 <- P.respond bs
                go size2

-- | Convert a handle into a byte stream using a fixed chunk size
hGetS
    :: (P.Proxy p) => Int -> Handle -> () -> P.Producer p BS.ByteString IO ()
hGetS size h () = P.runIdentityP go where
    go = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGet h size
                P.respond bs
                go

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetS_ :: (P.Proxy p) => Handle -> Int -> P.Server p Int BS.ByteString IO ()
hGetS_ h = P.runIdentityK go where
    go size = do
        eof <- lift $ hIsEOF h
        if eof
            then return ()
            else do
                bs <- lift $ BS.hGet h size
                size2 <- P.respond bs
                go size2


-- | Like 'isEndOfInput', except it also consumes and ignores leading empty
-- 'BS.ByteString' chunks.
isEndOfBytes
  :: (Monad m, P.Proxy p)
  => StateP [BS.ByteString] p () (Maybe BS.ByteString) y' y m Bool
isEndOfBytes = go where
    go = do
        ma <- draw
        case ma of
            Just a
              | BS.null a -> go
              | otherwise -> unDraw a >> return False
            Nothing       -> return True
{-# INLINABLE isEndOfBytes #-}


-- | @drawAllBytes@ folds all input bytes into a single strict 'BS.ByteString'
drawAllBytes
    :: (Monad m, P.Proxy p)
    => ()
    -> StateP [BS.ByteString] p () (Maybe BS.ByteString) y' y m BS.ByteString
drawAllBytes = fmap BS.concat . drawAll

-- | @drawBytesUpTo n@ returns at-most @n@ bytes from upstream.
passBytesUpTo
    :: (Monad m, P.Proxy p)
    => Int
    -> ()
    -> P.Pipe (StateP [BS.ByteString] p)
        (Maybe BS.ByteString) (Maybe BS.ByteString) m r
passBytesUpTo n0 = \() -> go n0
  where
    go n =
        if (n <= 0)
	then forever $ P.respond Nothing
	else do
	    mbs <- draw
	    case mbs of
	        Nothing -> forever $ P.respond Nothing
		Just bs -> do
		    let len = BS.length bs
		    if (len <= n)
		        then do
			    P.respond (Just bs)
			    go (n - len)
			else do
			    let (prefix, suffix) = BS.splitAt n bs
			    unDraw suffix
			    P.respond (Just prefix)
			    forever $ P.respond Nothing
