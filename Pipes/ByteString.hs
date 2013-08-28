{-#LANGUAGE RankNTypes#-}

{-| This module provides @pipes@ utilities for \"byte streams\", which are
    streams of strict 'BS.ByteString's chunks.  Use byte streams to interact
    with both 'IO.Handle's and lazy 'ByteString's.

    To stream to or from 'IO.Handle's, use 'fromHandle' or 'toHandle'.  For
    example, the following program copies data from one file to another:

> import Pipes
> import qualified Pipes.ByteString as P
> import System.IO
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runEffect $ P.fromHandle hIn >-> P.toHandle hOut

    You can also stream to and from 'stdin' and 'stdout' using the predefined
    'stdin' and 'stdout' proxies, like in the following \"echo\" program:

> main = runEffect $ P.stdin >-> stdout.P

    You can also translate pure lazy 'BL.ByteString's to and from proxies:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runProxy $ P.fromLazy (BL.pack "Hello, world!\n") >-> P.stdout

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform or fold byte streams.
-}

module Pipes.ByteString (
    -- * Introducing and Eliminating ByteStrings
    fromLazy,
    toLazy,
    
    -- * Basic Interface
    head,
    last,
    null,
    length,
    
    -- * Transforming ByteStrings
    map,
    
    -- * Reducing ByteStrings (folds)
    fold,
    
    -- ** Special folds
    concatMap,
    any,
    all,
    
    -- * Substrings
    -- ** Breaking strings
    take,
    drop,
    takeWhile,
    dropWhile,
    
    -- * Searching ByteStrings
    -- ** Searching by equality
    elem,
    notElem,
    
    -- ** Searching with a predicate
    find,
    filter,
    
    -- * Indexing ByteStrings
    index,
    elemIndex,
    elemIndices,
    findIndex,
    findIndices,
    count,
    
    -- * I/O with ByteStrings
    -- ** Standard input and output
    stdin,
    stdout,
    
    -- ** I/O with Handles
    fromHandle,
    toHandle,
    hGetSome,
    hGetSomeN,
    hGet,
    hGetN
    ) where

import Control.Monad (liftM)
import Control.Monad.Trans.Class (lift)
import Data.Functor.Identity (Identity)
import Pipes
import Pipes.Core (respond, Server')
import qualified Pipes.Prelude as P
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)
import qualified System.IO as IO
import qualified Data.List as List
import Prelude hiding (
    head,
    tail,
    last,
    length,
    map,
    foldr,
    init,
    concatMap,
    any,
    all,
    take,
    drop,
    takeWhile,
    dropWhile,
    elem,
    notElem,
    filter,
    null)


-- | Convert a lazy 'BL.ByteString' into a 'Producer' of strict 'BS.ByteString's
fromLazy :: (Monad m) => BL.ByteString -> Producer' BS.ByteString m ()
fromLazy bs =
   BLI.foldrChunks (\e a -> yield e >> a) (return ()) bs
{-# INLINABLE fromLazy #-}

{-| Fold a pure 'Producer' of strict 'BS.ByteString's into a lazy
    'BL.ByteString'
-}
toLazy :: Producer BS.ByteString Identity () -> BL.ByteString
toLazy = BL.fromChunks . P.toList
{-# INLINABLE toLazy #-}

{-| Fold an effectful 'Producer' of strict 'BS.ByteString's into a lazy
    'BL.ByteString'

    Note: 'toLazyM' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the chunks
    immediately as they are generated instead of loading them all into memory.
-}
toLazyM :: (Monad m) => Producer BS.ByteString m () -> m BL.ByteString
toLazyM = liftM BL.fromChunks . P.toListM
{-# INLINABLE toLazyM #-}

-- | Retrieve the first 'Word8'
head :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
head = go 
  where
    go p = do
        x <- next p
        case x of
            Left   ()      -> return Nothing
            Right (bs, p') ->
                if (BS.null bs)
                then go p'
                else return $ Just (BU.unsafeHead bs)
{-# INLINABLE head #-}

-- | Retrieve the last 'Word8'
last :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
last = go Nothing
  where
    go r p = do
        x <- next p
        case x of
            Left   ()      -> return r
            Right (bs, p') ->
                if (BS.null bs)
                then go r p'
                else go (Just $ BS.last bs) p'
                -- TODO: Change this to 'unsafeLast' when bytestring-0.10.2.0
                --       becomes more widespread
{-# INLINABLE last #-}

-- | Determine if the stream is empty
null :: (Monad m) => Producer BS.ByteString m () -> m Bool
null = P.all BS.null
{-# INLINABLE null #-}

-- | Count the number of bytes
length :: (Monad m, Num a) => Producer BS.ByteString m () -> m a
length = P.fold (\n bs -> n + fromIntegral (BS.length bs)) 0 id
{-# INLINABLE length #-}

-- | Apply a transformation to each 'Word8' in the stream
map :: (Monad m) => (Word8 -> Word8) -> Pipe BS.ByteString BS.ByteString m r
map f = P.map (BS.map f)
{-# INLINABLE map #-}

-- | Reduce the stream of bytes using a strict left fold
fold
    :: Monad m
    => (x -> Word8 -> x) -> x -> (x -> r) -> Producer BS.ByteString m () -> m r
fold step begin done = P.fold (\x bs -> BS.foldl' step x bs) begin done
{-# INLINABLE fold #-}

-- | Map a function over the byte stream and concatenate the results
concatMap
    :: (Monad m)
    => (Word8 -> BS.ByteString) -> Pipe BS.ByteString BS.ByteString m r
concatMap f = P.map (BS.concatMap f)
{-# INLINABLE concatMap #-}

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
any :: (Monad m) => (Word8 -> Bool) -> Producer BS.ByteString m () -> m Bool
any pred = P.any (BS.any pred)
{-# INLINABLE any #-}

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
all :: (Monad m) => (Word8 -> Bool) -> Producer BS.ByteString m () -> m Bool
all pred = P.all (BS.all pred)
{-# INLINABLE all #-}

-- | Return the maximum 'Word8' within a byte stream
maximum :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
maximum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else case mw8 of
            Nothing -> Just (BS.maximum bs)
            Just w8 -> Just (max w8 (BS.maximum bs))
{-# INLINABLE maximum #-}

-- | Return the minimum 'Word8' within a byte stream
minimum :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
minimum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else case mw8 of
            Nothing -> Just (BS.minimum bs)
            Just w8 -> Just (min w8 (BS.minimum bs))
{-# INLINABLE minimum #-}

-- | @(take n)@ only allows @n@ bytes to pass
take :: (Monad m, Integral a) => a -> Pipe BS.ByteString BS.ByteString m ()
take n0 = go n0 where
    go n
        | n <= 0    = return ()
        | otherwise = do
            bs <- await
            let len = fromIntegral $ BS.length bs
            if (len > n)
                then yield (BU.unsafeTake (fromIntegral n) bs)
                else do
                    yield bs
                    go (n - len)
{-# INLINABLE take #-}

-- | @(dropD n)@ drops the first @n@ bytes
drop :: (Monad m, Integral a) => a -> Pipe BS.ByteString BS.ByteString m r
drop n0 = go n0 where
    go n
        | n <= 0    = cat
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len >= n)
                then do
                    yield (BU.unsafeDrop (fromIntegral n) bs)
                    cat
                else go (n - len)
{-# INLINABLE drop #-}

-- | Take bytes until they fail the predicate
takeWhile
    :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m ()
takeWhile predicate = go where
    go = do
        bs <- await
        case BS.findIndex (not . predicate) bs of
            Nothing -> do
                yield bs
                go
            Just i -> yield (BU.unsafeTake i bs)
{-# INLINABLE takeWhile #-}

-- | Drop bytes until they fail the predicate
dropWhile
    :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m r
dropWhile predicate = go where
    go = do
        bs <- await
        case BS.findIndex (not . predicate) bs of
            Nothing -> go
            Just i -> do
                yield (BU.unsafeDrop i bs)
                cat
{-# INLINABLE dropWhile #-}

-- | Determine whether any element in the byte stream matches the given 'Word8'
elem :: (Monad m) => Word8 -> Producer BS.ByteString m () -> m Bool
elem w8 = P.any (BS.elem w8)
{-# INLINABLE elem #-}

{-| Determine whether all elements in the byte stream do not match the given
    'Word8'
-}
notElem
    :: (Monad m) => Word8 -> Producer BS.ByteString m () -> m Bool
notElem w8 = P.all (BS.notElem w8)
{-# INLINABLE notElem #-}

-- | Find the first element in the stream that matches the predicate
find
    :: (Monad m)
    => (Word8 -> Bool) -> Producer BS.ByteString m () -> m (Maybe Word8)
find predicate p = head (p >-> filter predicate)
{-# INLINABLE find #-}

-- | Only allows 'Word8's to pass if they satisfy the predicate
filter :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m r
filter pred = P.map (BS.filter pred)
{-# INLINABLE filter #-}

-- | Index into a byte stream
index
    :: (Monad m, Integral a)
    => a-> Producer BS.ByteString m () -> m (Maybe Word8)
index n p = head (p >-> drop n)
{-# INLINABLE index #-}

-- | Find the index of an element that matches the given 'Word8'
elemIndex
    :: (Monad m, Num a)
    => Word8 -> Producer BS.ByteString m () -> m (Maybe a)
elemIndex w8 = findIndex (w8 ==)
{-# INLINABLE elemIndex #-}

-- | Store a list of all indices whose elements match the given 'Word8'
elemIndices :: (Monad m, Num a) => Word8 -> Pipe BS.ByteString a m r
elemIndices w8 = findIndices (w8 ==)
{-# INLINABLE elemIndices #-}

-- | Store the first index of an element that satisfies the predicate
findIndex
    :: (Monad m, Num a)
    => (Word8 -> Bool) -> Producer BS.ByteString m () -> m (Maybe a)
findIndex predicate p = P.head (p >-> findIndices predicate)
{-# INLINABLE findIndex #-}

-- | Store a list of all indices whose elements satisfy the given predicate
findIndices :: (Monad m, Num a) => (Word8 -> Bool) -> Pipe BS.ByteString a m r
findIndices predicate = go 0
  where
    go n = do
        bs <- await
	each $ List.map (\i -> n + fromIntegral i) (BS.findIndices predicate bs)
        go $! n + fromIntegral (BS.length bs)
{-# INLINABLE findIndices #-}

-- | Store a tally of how many elements match the given 'Word8'
count :: (Monad m, Num a) => Word8 -> Producer BS.ByteString m () -> m a
count w8 p = P.fold (+) 0 id (p >-> P.map (fromIntegral . BS.count w8))
{-# INLINABLE count #-}

-- | Stream bytes from 'stdin'
stdin :: Producer' BS.ByteString IO ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

-- | Stream bytes to 'stdout'
stdout :: Consumer' BS.ByteString IO r
stdout = toHandle IO.stdout
{-# INLINABLE stdout #-}

-- | Convert a 'IO.Handle' into a byte stream using a default chunk size
fromHandle :: IO.Handle -> Producer' BS.ByteString IO ()
fromHandle = hGetSome BLI.defaultChunkSize
-- TODO: Test chunk size for performance
{-# INLINABLE fromHandle #-}

-- | Convert a byte stream into a 'Handle'
toHandle :: IO.Handle -> Consumer' BS.ByteString IO r
toHandle h = for cat (lift . BS.hPut h)
{-# INLINABLE toHandle #-}

-- | Convert a handle into a byte stream using a fixed chunk size
hGetSome :: Int -> IO.Handle -> Producer' BS.ByteString IO ()
hGetSome size h = go where
    go = do
        eof <- lift (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- lift (BS.hGetSome h size)
                yield bs
                go
{-# INLINABLE hGetSome #-}

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetSomeN :: IO.Handle -> Int -> Server' Int BS.ByteString IO ()
hGetSomeN h = go where
    go size = do
        eof <- lift (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- lift (BS.hGetSome h size)
                size2 <- respond bs
                go size2
{-# INLINABLE hGetSomeN #-}

-- | Convert a handle into a byte stream using a fixed chunk size
hGet :: Int -> IO.Handle -> Producer' BS.ByteString IO ()
hGet size h = go where
    go = do
        eof <- lift (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- lift (BS.hGet h size)
                yield bs
                go
{-# INLINABLE hGet #-}

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetN :: IO.Handle -> Int -> Server' Int BS.ByteString IO ()
hGetN h = go where
    go size = do
        eof <- lift (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- lift $ BS.hGet h size
                size2 <- respond bs
                go size2
{-# INLINABLE hGetN #-}
