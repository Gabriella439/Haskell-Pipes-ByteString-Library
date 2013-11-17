{-# LANGUAGE RankNTypes, CPP #-}

-- The rewrite rules require the Trustworthy annotation
#if __GLASGOW_HASKELL__ >= 702
{-# LANGUAGE Trustworthy #-}
#endif

{-| This module provides @pipes@ utilities for \"byte streams\", which are
    streams of strict 'ByteString's chunks.  Use byte streams to interact
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

    You can stream to and from 'stdin' and 'stdout' using the predefined 'stdin'
    and 'stdout' proxies, like in the following \"echo\" program:

> main = runEffect $ P.stdin >-> P.stdout

    You can also translate pure lazy 'BL.ByteString's to and from proxies:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runEffect $ P.fromLazy (BL.pack "Hello, world!\n") >-> P.stdout

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform or fold byte streams.  For
    example, to stream only the first three lines of 'stdin' to 'stdout' you
    would write:

> import Pipes
> import qualified Pipes.ByteString as PB
> import qualified Pipes.Parse      as PP
>
> main = runEffect $ takeLines 3 PB.stdin >-> PB.stdout
>   where
>     takeLines n = PB.unlines . PP.takeFree n . PB.lines

    The above program will never bring more than one chunk (~ 32 KB) into
    memory, no matter how long the lines are.

    Note that functions in this library are designed to operate on streams that
    are insensitive to chunk boundaries.  This means that they may freely split
    chunks into smaller chunks and /discard empty chunks/.  However, they will
    /never concatenate chunks/ in order to provide strict upper bounds on memory
    usage.
-}

module Pipes.ByteString (
    -- * Producers
    fromLazy,
    stdin,
    fromHandle,
    hGetSome,
    hGet,
    pack,

    -- * Servers
    hGetSomeN,
    hGetN,

    -- * Consumers
    stdout,
    toHandle,

    -- * Pipes
    map,
    concatMap,
    take,
    drop,
    takeWhile,
    dropWhile,
    filter,
    elemIndices,
    findIndices,
    scan,
    unpack,

    -- * Folds
    toLazy,
    toLazyM,
    fold,
    head,
    last,
    null,
    length,
    any,
    all,
    maximum,
    minimum,
    elem,
    notElem,
    find,
    index,
    elemIndex,
    findIndex,
    count,

    -- * Splitters
    splitAt,
    chunksOf,
    span,
    break,
    splitWith,
    split,
    groupBy,
    group,
    lines,
    words,

    -- * Transformations
    intersperse,

    -- * Joiners
    intercalate,
    unlines,
    unwords,

    -- * Low-level Parsers
    -- $parse
    nextByte,
    drawByte,
    unDrawByte,
    peekByte,
    isEndOfBytes,
    takeWhile',

    -- * Re-exports
    -- $reexports
    module Data.ByteString,
    module Data.Word,
    module Pipes.Parse
    ) where

import Control.Exception (throwIO, try)
import Control.Monad (liftM)
import Control.Monad.Trans.State.Strict (StateT)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.ByteString.Internal (isSpaceWord8)
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Lazy.Internal (foldrChunks, defaultChunkSize)
import Data.ByteString.Unsafe (unsafeTake, unsafeDrop)
import Data.Char (ord)
import Data.Functor.Identity (Identity)
import qualified Data.List as List
import Data.Word (Word8)
import Foreign.C.Error (Errno(Errno), ePIPE)
import qualified GHC.IO.Exception as G
import Pipes
import qualified Pipes.ByteString.Parse as PBP
import Pipes.ByteString.Parse (
    nextByte, drawByte, unDrawByte, peekByte, isEndOfBytes )
import Pipes.Core (respond, Server')
import Pipes.Lift (evalStateP)
import qualified Pipes.Parse as PP
import Pipes.Parse (input, concat, FreeT, isEndOfInput)
import qualified Pipes.Prelude as P
import qualified System.IO as IO
import Prelude hiding (
    all,
    any,
    break,
    concat,
    concatMap,
    drop,
    dropWhile,
    elem,
    filter,
    head,
    last,
    lines,
    length,
    map,
    maximum,
    minimum,
    notElem,
    null,
    span,
    splitAt,
    take,
    takeWhile,
    unlines,
    unwords,
    words )

-- | Convert a lazy 'BL.ByteString' into a 'Producer' of strict 'ByteString's
fromLazy :: (Monad m) => BL.ByteString -> Producer' ByteString m ()
fromLazy bs = foldrChunks (\e a -> yield e >> a) (return ()) bs
{-# INLINABLE fromLazy #-}

-- | Stream bytes from 'stdin'
stdin :: MonadIO m => Producer' ByteString m ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

-- | Convert a 'IO.Handle' into a byte stream using a default chunk size
fromHandle :: MonadIO m => IO.Handle -> Producer' ByteString m ()
fromHandle = hGetSome defaultChunkSize
-- TODO: Test chunk size for performance
{-# INLINABLE fromHandle #-}

{-| Convert a handle into a byte stream using a maximum chunk size

    'hGetSome' forwards input immediately as it becomes available, splitting the
    input into multiple chunks if it exceeds the maximum chunk size.
-}
hGetSome :: MonadIO m => Int -> IO.Handle -> Producer' ByteString m ()
hGetSome size h = go where
    go = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- liftIO (BS.hGetSome h size)
                yield bs
                go
{-# INLINABLE hGetSome #-}

{-| Convert a handle into a byte stream using a fixed chunk size

    'hGet' waits until exactly the requested number of bytes are available for
    each chunk.
-}
hGet :: MonadIO m => Int -> IO.Handle -> Producer' ByteString m ()
hGet size h = go where
    go = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- liftIO (BS.hGet h size)
                yield bs
                go
{-# INLINABLE hGet #-}

-- | Convert a 'Word8' producer into a byte stream using a default chunk size
pack :: Monad m => Producer Word8 m () -> Producer ByteString m ()
pack p = evalStateP p go where
    go = do
        eof <- lift isEndOfInput
        if eof
            then return ()
            else do
                bytes <- lift $ P.toListM (P.take defaultChunkSize <-< input)
                yield $ BS.pack bytes
                go
{-# INLINABLE pack #-}

{-| Like 'hGetSome', except you can vary the maximum chunk size for each request
-}
hGetSomeN :: MonadIO m => IO.Handle -> Int -> Server' Int ByteString m ()
hGetSomeN h = go where
    go size = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- liftIO (BS.hGetSome h size)
                size2 <- respond bs
                go size2
{-# INLINABLE hGetSomeN #-}

-- | Like 'hGet', except you can vary the chunk size for each request
hGetN :: MonadIO m => IO.Handle -> Int -> Server' Int ByteString m ()
hGetN h = go where
    go size = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- liftIO (BS.hGet h size)
                size2 <- respond bs
                go size2
{-# INLINABLE hGetN #-}

{-| Stream bytes to 'stdout'

    Unlike 'toHandle', 'stdout' gracefully terminates on a broken output pipe.

    Note: For best performance, use @(for source (liftIO . putStr))@ instead of
    @(source >-> stdout)@.
-}
stdout :: MonadIO m => Consumer' ByteString m ()
stdout = go
  where
    go = do
        bs <- await
        x  <- liftIO $ try (BS.putStr bs)
        case x of
            Left (G.IOError { G.ioe_type  = G.ResourceVanished
                            , G.ioe_errno = Just ioe })
                 | Errno ioe == ePIPE
                     -> return ()
            Left  e  -> liftIO (throwIO e)
            Right () -> go
{-# INLINABLE stdout #-}

{-| Convert a byte stream into a 'Handle'

    Note: For best performance, use @(for source (liftIO . hPutStr handle))@
    instead of @(source >-> toHandle handle)@.
-}
toHandle :: MonadIO m => IO.Handle -> Consumer' ByteString m r
toHandle h = for cat (liftIO . BS.hPut h)
{-# INLINABLE toHandle #-}

{-# RULES "p >-> toHandle h" forall p h .
        p >-> toHandle h = for p (\bs -> liftIO (BS.hPut h bs))
  #-}

-- | Apply a transformation to each 'Word8' in the stream
map :: (Monad m) => (Word8 -> Word8) -> Pipe ByteString ByteString m r
map f = P.map (BS.map f)
{-# INLINABLE map #-}

-- | Map a function over the byte stream and concatenate the results
concatMap
    :: (Monad m) => (Word8 -> ByteString) -> Pipe ByteString ByteString m r
concatMap f = P.map (BS.concatMap f)
{-# INLINABLE concatMap #-}

-- | @(take n)@ only allows @n@ bytes to pass
take :: (Monad m, Integral a) => a -> Pipe ByteString ByteString m ()
take n0 = go n0 where
    go n
        | n <= 0    = return ()
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len > n)
                then yield (unsafeTake (fromIntegral n) bs)
                else do
                    yield bs
                    go (n - len)
{-# INLINABLE take #-}

-- | @(drop n)@ drops the first @n@ bytes
drop :: (Monad m, Integral a) => a -> Pipe ByteString ByteString m r
drop n0 = go n0 where
    go n
        | n <= 0    = cat
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len >= n)
                then do
                    yield (unsafeDrop (fromIntegral n) bs)
                    cat
                else go (n - len)
{-# INLINABLE drop #-}

-- | Take bytes until they fail the predicate
takeWhile :: (Monad m) => (Word8 -> Bool) -> Pipe ByteString ByteString m ()
takeWhile predicate = go
  where
    go = do
        bs <- await
        let (prefix, suffix) = BS.span predicate bs
        if (BS.null suffix)
            then do
                yield bs
                go
            else yield prefix
{-# INLINABLE takeWhile #-}

-- | Drop bytes until they fail the predicate
dropWhile :: (Monad m) => (Word8 -> Bool) -> Pipe ByteString ByteString m r
dropWhile predicate = go where
    go = do
        bs <- await
        case BS.findIndex (not . predicate) bs of
            Nothing -> go
            Just i -> do
                yield (unsafeDrop i bs)
                cat
{-# INLINABLE dropWhile #-}

-- | Only allows 'Word8's to pass if they satisfy the predicate
filter :: (Monad m) => (Word8 -> Bool) -> Pipe ByteString ByteString m r
filter predicate = P.map (BS.filter predicate)
{-# INLINABLE filter #-}

-- | Stream all indices whose elements match the given 'Word8'
elemIndices :: (Monad m, Num n) => Word8 -> Pipe ByteString n m r
elemIndices w8 = findIndices (w8 ==)
{-# INLINABLE elemIndices #-}

-- | Stream all indices whose elements satisfy the given predicate
findIndices :: (Monad m, Num n) => (Word8 -> Bool) -> Pipe ByteString n m r
findIndices predicate = go 0
  where
    go n = do
        bs <- await
	each $ List.map (\i -> n + fromIntegral i) (BS.findIndices predicate bs)
        go $! n + fromIntegral (BS.length bs)
{-# INLINABLE findIndices #-}

-- | Strict left scan over the bytes
scan
    :: (Monad m)
    => (Word8 -> Word8 -> Word8) -> Word8 -> Pipe ByteString ByteString m r
scan step begin = go begin
  where
    go w8 = do
        bs <- await
        let bs' = BS.scanl step w8 bs
            w8' = BS.last bs'
        yield bs'
        go w8'
{-# INLINABLE scan #-}

-- | Unpack the bytes
unpack :: Monad m => Pipe ByteString Word8 m ()
unpack = for cat (mapM_ yield . BS.unpack)
{-# INLINABLE unpack #-}

{-# RULES
    "p >-> unpack" forall p .
        p >-> unpack = for p (\bs -> mapM_ yield (BS.unpack bs))
  #-}

{-| Fold a pure 'Producer' of strict 'ByteString's into a lazy
    'BL.ByteString'
-}
toLazy :: Producer ByteString Identity () -> BL.ByteString
toLazy = BL.fromChunks . P.toList
{-# INLINABLE toLazy #-}

{-| Fold an effectful 'Producer' of strict 'ByteString's into a lazy
    'BL.ByteString'

    Note: 'toLazyM' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the chunks
    immediately as they are generated instead of loading them all into memory.
-}
toLazyM :: (Monad m) => Producer ByteString m () -> m BL.ByteString
toLazyM = liftM BL.fromChunks . P.toListM
{-# INLINABLE toLazyM #-}

-- | Reduce the stream of bytes using a strict left fold
fold
    :: Monad m
    => (x -> Word8 -> x) -> x -> (x -> r) -> Producer ByteString m () -> m r
fold step begin done = P.fold (\x bs -> BS.foldl' step x bs) begin done
{-# INLINABLE fold #-}

-- | Retrieve the first 'Word8'
head :: (Monad m) => Producer ByteString m () -> m (Maybe Word8)
head = go
  where
    go p = do
        x <- nextByte p
        return $ case x of
            Left   _      -> Nothing
            Right (w8, _) -> Just w8
{-# INLINABLE head #-}

-- | Retrieve the last 'Word8'
last :: (Monad m) => Producer ByteString m () -> m (Maybe Word8)
last = go Nothing
  where
    go r p = do
        x <- next p
        case x of
            Left   ()      -> return r
            Right (bs, p') ->
                go (if BS.null bs then r else (Just $ BS.last bs)) p'
                -- TODO: Change this to 'unsafeLast' when bytestring-0.10.2.0
                --       becomes more widespread
{-# INLINABLE last #-}

-- | Determine if the stream is empty
null :: (Monad m) => Producer ByteString m () -> m Bool
null = P.all BS.null
{-# INLINABLE null #-}

-- | Count the number of bytes
length :: (Monad m, Num n) => Producer ByteString m () -> m n
length = P.fold (\n bs -> n + fromIntegral (BS.length bs)) 0 id
{-# INLINABLE length #-}

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
any :: (Monad m) => (Word8 -> Bool) -> Producer ByteString m () -> m Bool
any predicate = P.any (BS.any predicate)
{-# INLINABLE any #-}

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
all :: (Monad m) => (Word8 -> Bool) -> Producer ByteString m () -> m Bool
all predicate = P.all (BS.all predicate)
{-# INLINABLE all #-}

-- | Return the maximum 'Word8' within a byte stream
maximum :: (Monad m) => Producer ByteString m () -> m (Maybe Word8)
maximum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else Just $ case mw8 of
            Nothing -> BS.maximum bs
            Just w8 -> max w8 (BS.maximum bs)
{-# INLINABLE maximum #-}

-- | Return the minimum 'Word8' within a byte stream
minimum :: (Monad m) => Producer ByteString m () -> m (Maybe Word8)
minimum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else case mw8 of
            Nothing -> Just (BS.minimum bs)
            Just w8 -> Just (min w8 (BS.minimum bs))
{-# INLINABLE minimum #-}

-- | Determine whether any element in the byte stream matches the given 'Word8'
elem :: (Monad m) => Word8 -> Producer ByteString m () -> m Bool
elem w8 = P.any (BS.elem w8)
{-# INLINABLE elem #-}

{-| Determine whether all elements in the byte stream do not match the given
    'Word8'
-}
notElem :: (Monad m) => Word8 -> Producer ByteString m () -> m Bool
notElem w8 = P.all (BS.notElem w8)
{-# INLINABLE notElem #-}

-- | Find the first element in the stream that matches the predicate
find
    :: (Monad m)
    => (Word8 -> Bool) -> Producer ByteString m () -> m (Maybe Word8)
find predicate p = head (p >-> filter predicate)
{-# INLINABLE find #-}

-- | Index into a byte stream
index
    :: (Monad m, Integral a)
    => a-> Producer ByteString m () -> m (Maybe Word8)
index n p = head (p >-> drop n)
{-# INLINABLE index #-}

-- | Find the index of an element that matches the given 'Word8'
elemIndex
    :: (Monad m, Num n) => Word8 -> Producer ByteString m () -> m (Maybe n)
elemIndex w8 = findIndex (w8 ==)
{-# INLINABLE elemIndex #-}

-- | Store the first index of an element that satisfies the predicate
findIndex
    :: (Monad m, Num n)
    => (Word8 -> Bool) -> Producer ByteString m () -> m (Maybe n)
findIndex predicate p = P.head (p >-> findIndices predicate)
{-# INLINABLE findIndex #-}

-- | Store a tally of how many elements match the given 'Word8'
count :: (Monad m, Num n) => Word8 -> Producer ByteString m () -> m n
count w8 p = P.fold (+) 0 id (p >-> P.map (fromIntegral . BS.count w8))
{-# INLINABLE count #-}

-- | Splits a 'Producer' after the given number of bytes
splitAt
    :: (Monad m, Integral n)
    => n
    -> Producer ByteString m r
    -> Producer' ByteString m (Producer ByteString m r)
splitAt = go
  where
    go 0 p = return p
    go n p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (return r)
            Right (bs, p') -> do
                let len = fromIntegral (BS.length bs)
                if (len <= n)
                    then do
                        yield bs
                        go (n - len) p'
                    else do
                        let (prefix, suffix) = BS.splitAt (fromIntegral n) bs
                        yield prefix
                        return (yield suffix >> p')
{-# INLINABLE splitAt #-}

-- | Split a byte stream into 'FreeT'-delimited byte streams of fixed size
chunksOf
    :: (Monad m, Integral n)
    => n -> Producer ByteString m r -> FreeT (Producer ByteString m) m r
chunksOf n = go
  where
    go p = PP.FreeT $ do
        x <- next p
        return $ case x of
            Left   r       -> PP.Pure r
            Right (bs, p') -> PP.Free $ do
                p'' <- splitAt n (yield bs >> p')
                return (go p'')
{-# INLINABLE chunksOf #-}

{-| Split a byte stream in two, where the first byte stream is the longest
    consecutive group of bytes that satisfy the predicate
-}
span
    :: (Monad m)
    => (Word8 -> Bool)
    -> Producer  ByteString m  r
    -> Producer' ByteString m (Producer ByteString m r)
span predicate = go
  where
    go p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (return r)
            Right (bs, p') -> do
                let (prefix, suffix) = BS.span predicate bs
                if (BS.null suffix)
                    then do
                        yield bs
                        go p'
                    else do
                        yield prefix
                        return (yield suffix >> p')
{-# INLINABLE span #-}

{-| Split a byte stream in two, where the first byte stream is the longest
    consecutive group of bytes that don't satisfy the predicate
-}
break
    :: (Monad m)
    => (Word8 -> Bool)
    -> Producer ByteString m  r
    -> Producer ByteString m (Producer ByteString m r)
break predicate = span (not . predicate)
{-# INLINABLE break #-}

{-| Split a byte stream into sub-streams delimited by bytes that satisfy the
    predicate
-}
splitWith
    :: (Monad m)
    => (Word8 -> Bool)
    -> Producer ByteString m r
    -> PP.FreeT (Producer ByteString m) m r
splitWith predicate p0 = PP.FreeT (go0 p0)
  where
    go0 p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (bs, p') ->
                if (BS.null bs)
                then go0 p'
                else go1 (yield bs >> p')
    go1 p = return $ PP.Free $ do
        p' <- span (not . predicate) p
        return $ PP.FreeT $ do
            x <- nextByte p'
            case x of
                Left   r       -> return (PP.Pure r)
                Right (_, p'') -> go1 p''
{-# INLINABLE splitWith #-}

-- | Split a byte stream using the given 'Word8' as the delimiter
split :: (Monad m)
      => Word8
      -> Producer ByteString m r
      -> FreeT (Producer ByteString m) m r
split w8 = splitWith (w8 ==)
{-# INLINABLE split #-}

{-| Group a byte stream into 'FreeT'-delimited byte streams using the supplied
    equality predicate
-}
groupBy
    :: (Monad m)
    => (Word8 -> Word8 -> Bool)
    -> Producer ByteString m r
    -> FreeT (Producer ByteString m) m r
groupBy equal p0 = PP.FreeT (go p0)
  where
    go p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (bs, p') -> case (BS.uncons bs) of
                Nothing      -> go p'
                Just (w8, _) -> do
                    return $ PP.Free $ do
                        p'' <- span (equal w8) (yield bs >> p')
                        return $ PP.FreeT (go p'')
{-# INLINABLE groupBy #-}

-- | Group a byte stream into 'FreeT'-delimited byte streams of identical bytes
group
    :: (Monad m) => Producer ByteString m r -> FreeT (Producer ByteString m) m r
group = groupBy (==)
{-# INLINABLE group #-}

{-| Split a byte stream into 'FreeT'-delimited lines

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
lines
    :: (Monad m) => Producer ByteString m r -> FreeT (Producer ByteString m) m r
lines p0 = PP.FreeT (go0 p0)
  where
    go0 p = do
        x <- next p
        case x of
            Left   r       -> return (PP.Pure r)
            Right (bs, p') ->
                if (BS.null bs)
                then go0 p'
                else return $ PP.Free $ go1 (yield bs >> p')
    go1 p = do
        p' <- break (fromIntegral (ord '\n') ==) p
        return $ PP.FreeT $ do
            x  <- nextByte p'
            case x of
                Left   r       -> return (PP.Pure r)
                Right (_, p'') -> go0 p''
{-# INLINABLE lines #-}

{-| Split a byte stream into 'FreeT'-delimited words

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
words
    :: (Monad m) => Producer ByteString m r -> FreeT (Producer ByteString m) m r
words = go
  where
    go p = PP.FreeT $ do
        x <- next (p >-> dropWhile isSpaceWord8)
        return $ case x of
            Left   r       -> PP.Pure r
            Right (bs, p') -> PP.Free $ do
                p'' <- break isSpaceWord8 (yield bs >> p')
                return (go p'')
{-# INLINABLE words #-}

-- | Intersperse a 'Word8' in between the bytes of the byte stream
intersperse
    :: (Monad m) => Word8 -> Producer ByteString m r -> Producer ByteString m r
intersperse w8 = go0
  where
    go0 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (bs, p') -> do
                yield (BS.intersperse w8 bs)
                go1 p'
    go1 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (bs, p') -> do
                yield (BS.singleton w8)
                yield (BS.intersperse w8 bs)
                go1 p'
{-# INLINABLE intersperse #-}

{-| 'intercalate' concatenates the 'FreeT'-delimited byte streams after
    interspersing a byte stream in between them
-}
intercalate
    :: (Monad m)
    => Producer ByteString m ()
    -> FreeT (Producer ByteString m) m r
    -> Producer ByteString m r
intercalate p0 = go0
  where
    go0 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                go1 f'
    go1 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                p0
                f' <- p
                go1 f'
{-# INLINABLE intercalate #-}

{-| Join 'FreeT'-delimited lines into a byte stream

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
unlines
    :: (Monad m) => FreeT (Producer ByteString m) m r -> Producer ByteString m r
unlines = go
  where
    go f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                yield $ BS.singleton $ fromIntegral (ord '\n')
                go f'
{-# INLINABLE unlines #-}

{-| Join 'FreeT'-delimited words into a byte stream

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
unwords
    :: (Monad m) => FreeT (Producer ByteString m) m r -> Producer ByteString m r
unwords = intercalate (yield $ BS.singleton $ fromIntegral $ ord ' ')
{-# INLINABLE unwords #-}

{- $parse
    The following parsing utilities are single-byte analogs of the ones found
    in @pipes-parse@.
-}

{-| Take bytes until they fail the predicate

    Unlike 'takeWhile', this 'PP.unDraw's unused bytes
-}
takeWhile'
    :: (Monad m)
    => (Word8 -> Bool)
    -> Pipe ByteString ByteString (StateT (Producer ByteString m r) m) ()
takeWhile' = PBP.takeWhile
{-# INLINABLE takeWhile' #-}
{-# DEPRECATED takeWhile' "Use Pipes.ByteString.Parse.takeWhile instead" #-}

{- $reexports
    "Pipes.ByteString.Parse" re-exports 'nextByte', 'drawByte', 'unDrawByte',
    'peekByte', and 'isEndOfBytes'.
    
    @Data.ByteString@ re-exports the 'ByteString' type.

    @Data.Word@ re-exports the 'Word8' type.

    @Pipes.Parse@ re-exports 'input', 'concat', and 'FreeT' (the type).
-}
