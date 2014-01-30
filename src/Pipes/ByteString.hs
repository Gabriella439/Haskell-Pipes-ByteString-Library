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
    and 'stdout' pipes, like in the following \"echo\" program:

> main = runEffect $ P.stdin >-> P.stdout

    You can also translate pure lazy 'BL.ByteString's to and from pipes:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runEffect $ P.fromLazy (BL.pack "Hello, world!\n") >-> P.stdout

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform or fold byte streams.  For
    example, to stream only the first three lines of 'stdin' to 'stdout' you
    would write:

> import Lens.Family (over)
> import Pipes
> import qualified Pipes.ByteString as PB
> import Pipes.Parse (takes)
>
> main = runEffect $ over PB.lines (takes 3) PB.stdin >-> PB.stdout

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
      fromLazy
    , stdin
    , fromHandle
    , hGetSome
    , hGet

    -- * Servers
    , hGetSomeN
    , hGetN

    -- * Consumers
    , stdout
    , toHandle

    -- * Pipes
    , map
    , concatMap
    , take
    , drop
    , takeWhile
    , dropWhile
    , filter
    , elemIndices
    , findIndices
    , scan

    -- * Folds
    , toLazy
    , toLazyM
    , foldBytes
    , head
    , last
    , null
    , length
    , any
    , all
    , maximum
    , minimum
    , elem
    , notElem
    , find
    , index
    , elemIndex
    , findIndex
    , count

    -- * Parsing
    -- $parse
    , nextByte
    , drawByte
    , unDrawByte
    , peekByte
    , isEndOfBytes

    -- * Parsing Lenses
    , splitAt
    , span
    , break
    , groupBy
    , group
    , word
    , line
    , intersperse
    , pack
    , chunksOf'

    -- * FreeT
    , chunksOf
    , splitsWith
    , splits
    , groupsBy
    , groups
    , lines
    , words

    -- * Re-exports
    -- $reexports
    , module Data.ByteString
    , module Data.Profunctor
    , module Data.Word
    , module Lens.Family
    , module Pipes.Group
    , module Pipes.Parse
    ) where

import Control.Applicative ((<*))
import Control.Exception (throwIO, try)
import Control.Monad (liftM, join)
import Control.Monad.Trans.State.Strict (modify)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import Data.ByteString.Internal (isSpaceWord8)
import qualified Data.ByteString.Lazy as BL
import Data.ByteString.Lazy.Internal (foldrChunks, defaultChunkSize)
import Data.ByteString.Unsafe (unsafeTake, unsafeDrop)
import Data.Char (ord)
import Data.Functor.Identity (Identity)
import Data.Profunctor (Profunctor)
import qualified Data.Profunctor
import qualified Data.List as List
import Data.Word (Word8)
import Foreign.C.Error (Errno(Errno), ePIPE)
import qualified GHC.IO.Exception as G
import Lens.Family (Phantom)
import Lens.Family as NoReexport
import Pipes
import Pipes.Core (respond, Server')
import qualified Pipes.Group as PG
import Pipes.Group (concats, intercalates, FreeT)
import qualified Pipes.Parse as PP
import Pipes.Parse (Parser)
import qualified Pipes.Prelude as P
import qualified System.IO as IO
import Prelude hiding (
      all
    , any
    , break
    , concatMap
    , drop
    , dropWhile
    , elem
    , filter
    , head
    , last
    , lines
    , length
    , map
    , maximum
    , minimum
    , notElem
    , null
    , span
    , splitAt
    , take
    , takeWhile
    , words
    )

-- | Convert a lazy 'BL.ByteString' into a 'Producer' of strict 'ByteString's
fromLazy :: Monad m => BL.ByteString -> Producer' ByteString m ()
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
hGetSome size h = go
  where
    go = do
        bs <- liftIO (BS.hGetSome h size)
        if (BS.null bs)
            then return ()
            else do
                yield bs
                go
{-# INLINABLE hGetSome #-}

{-| Convert a handle into a byte stream using a fixed chunk size

    'hGet' waits until exactly the requested number of bytes are available for
    each chunk.
-}
hGet :: MonadIO m => Int -> IO.Handle -> Producer' ByteString m ()
hGet size h = go
  where
    go = do
        bs <- liftIO (BS.hGet h size)
        if (BS.null bs)
            then return ()
            else do
                yield bs
                go
{-# INLINABLE hGet #-}

{-| Like 'hGetSome', except you can vary the maximum chunk size for each request
-}
hGetSomeN :: MonadIO m => IO.Handle -> Int -> Server' Int ByteString m ()
hGetSomeN h = go
  where
    go size = do
        bs <- liftIO (BS.hGetSome h size)
        if (BS.null bs)
            then return ()
            else do
                size2 <- respond bs
                go size2
{-# INLINABLE hGetSomeN #-}

-- | Like 'hGet', except you can vary the chunk size for each request
hGetN :: MonadIO m => IO.Handle -> Int -> Server' Int ByteString m ()
hGetN h = go
  where
    go size = do
        bs <- liftIO (BS.hGet h size)
        if (BS.null bs)
            then return ()
            else do
                size2 <- respond bs
                go size2
{-# INLINABLE hGetN #-}

{-| Stream bytes to 'stdout'

    Unlike 'toHandle', 'stdout' gracefully terminates on a broken output pipe.
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

> p >-> toHandle handle = for p (liftIO . hPutStr handle)
-}
toHandle :: MonadIO m => IO.Handle -> Consumer' ByteString m r
toHandle h = for cat (liftIO . BS.hPut h)
{-# INLINABLE toHandle #-}

{-# RULES "p >-> toHandle h" forall p h .
        p >-> toHandle h = for p (\bs -> liftIO (BS.hPut h bs))
  #-}

-- | Apply a transformation to each 'Word8' in the stream
map :: Monad m => (Word8 -> Word8) -> Pipe ByteString ByteString m r
map f = P.map (BS.map f)
{-# INLINABLE map #-}

-- | Map a function over the byte stream and concatenate the results
concatMap
    :: Monad m => (Word8 -> ByteString) -> Pipe ByteString ByteString m r
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
takeWhile :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m ()
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
dropWhile :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m r
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
filter :: Monad m => (Word8 -> Bool) -> Pipe ByteString ByteString m r
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
    :: Monad m
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
toLazyM :: Monad m => Producer ByteString m () -> m BL.ByteString
toLazyM = liftM BL.fromChunks . P.toListM
{-# INLINABLE toLazyM #-}

{-| Reduce the stream of bytes using a strict left fold

    Note: It's more efficient to use folds from @Control.Foldl.ByteString@ in
    conjunction with @Pipes.Prelude.'Pipes.Prelude.fold'@ when possible
-}
foldBytes
    :: Monad m
    => (x -> Word8 -> x) -> x -> (x -> r) -> Producer ByteString m () -> m r
foldBytes step begin done = P.fold (\x bs -> BS.foldl' step x bs) begin done
{-# INLINABLE foldBytes #-}

-- | Retrieve the first 'Word8'
head :: Monad m => Producer ByteString m () -> m (Maybe Word8)
head = go
  where
    go p = do
        x <- nextByte p
        return $ case x of
            Left   _      -> Nothing
            Right (w8, _) -> Just w8
{-# INLINABLE head #-}

-- | Retrieve the last 'Word8'
last :: Monad m => Producer ByteString m () -> m (Maybe Word8)
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
null :: Monad m => Producer ByteString m () -> m Bool
null = P.all BS.null
{-# INLINABLE null #-}

-- | Count the number of bytes
length :: (Monad m, Num n) => Producer ByteString m () -> m n
length = P.fold (\n bs -> n + fromIntegral (BS.length bs)) 0 id
{-# INLINABLE length #-}

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
any :: Monad m => (Word8 -> Bool) -> Producer ByteString m () -> m Bool
any predicate = P.any (BS.any predicate)
{-# INLINABLE any #-}

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
all :: Monad m => (Word8 -> Bool) -> Producer ByteString m () -> m Bool
all predicate = P.all (BS.all predicate)
{-# INLINABLE all #-}

-- | Return the maximum 'Word8' within a byte stream
maximum :: Monad m => Producer ByteString m () -> m (Maybe Word8)
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
minimum :: Monad m => Producer ByteString m () -> m (Maybe Word8)
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
elem :: Monad m => Word8 -> Producer ByteString m () -> m Bool
elem w8 = P.any (BS.elem w8)
{-# INLINABLE elem #-}

{-| Determine whether all elements in the byte stream do not match the given
    'Word8'
-}
notElem :: Monad m => Word8 -> Producer ByteString m () -> m Bool
notElem w8 = P.all (BS.notElem w8)
{-# INLINABLE notElem #-}

-- | Find the first element in the stream that matches the predicate
find
    :: Monad m
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

{-| Consume the first byte from a byte stream

    'next' either fails with a 'Left' if the 'Producer' has no more bytes or
    succeeds with a 'Right' providing the next byte and the remainder of the
    'Producer'.
-}
nextByte
    :: Monad m
    => Producer ByteString m r
    -> m (Either r (Word8, Producer ByteString m r))
nextByte = go
  where
    go p = do
        x <- next p
        case x of
            Left   r       -> return (Left r)
            Right (bs, p') -> case (BS.uncons bs) of
                Nothing        -> go p'
                Just (w8, bs') -> return (Right (w8, yield bs' >> p'))
{-# INLINABLE nextByte #-}

{-| Draw one 'Word8' from the underlying 'Producer', returning 'Nothing' if the
    'Producer' is empty
-}
drawByte :: Monad m => Parser ByteString m (Maybe Word8)
drawByte = do
    x <- PP.draw
    case x of
        Nothing -> return Nothing
        Just bs -> case (BS.uncons bs) of
            Nothing        -> drawByte
            Just (w8, bs') -> do
                PP.unDraw bs'
                return (Just w8)
{-# INLINABLE drawByte #-}

-- | Push back a 'Word8' onto the underlying 'Producer'
unDrawByte :: Monad m => Word8 -> Parser ByteString m ()
unDrawByte w8 = modify (yield (BS.singleton w8) >>)
{-# INLINABLE unDrawByte #-}

{-| 'peekByte' checks the first 'Word8' in the stream, but uses 'unDrawByte' to
    push the 'Word8' back

> peekByte = do
>     x <- drawByte
>     case x of
>         Nothing -> return ()
>         Just w8 -> unDrawByte w8
>     return x
-}
peekByte :: Monad m => Parser ByteString m (Maybe Word8)
peekByte = do
    x <- drawByte
    case x of
        Nothing -> return ()
        Just w8 -> unDrawByte w8
    return x
{-# INLINABLE peekByte #-}

{-| Check if the underlying 'Producer' has no more bytes

    Note that this will skip over empty 'ByteString' chunks, unlike
    'Pipes.Parse.isEndOfInput' from @pipes-parse@.

> isEndOfBytes = liftM isNothing peekByte
-}
isEndOfBytes :: Monad m => Parser ByteString m Bool
isEndOfBytes = do
    x <- peekByte
    return (case x of
        Nothing -> True
        Just _  -> False )
{-# INLINABLE isEndOfBytes #-}

type Getter' a b = forall f . Phantom f => (b -> f b) -> (a -> f a)
type Lens'   a b = forall f . Functor f => (b -> f b) -> (a -> f a)

type Iso' a b = forall f p . (Functor f, Profunctor p) => p b (f b) -> p a (f a)

-- | Improper lens that splits a 'Producer' after the given number of bytes
splitAt
    :: (Monad m, Integral n)
    => n
    -> Lens' (Producer ByteString m x)
             (Producer ByteString m (Producer ByteString m x))
splitAt n0 k p0 = fmap join (k (go n0 p0))
  where
    -- go  :: (Monad m, Integral n)
    --     => n
    --     -> Producer ByteString m r
    --     -> Producer' ByteString m (Producer ByteString m r)
    go n p =
        if (n <= 0)
        then return p
	else do
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
                            let (prefix, suffix) =
                                    BS.splitAt (fromIntegral n) bs
                            yield prefix
                            return (yield suffix >> p')
{-# INLINABLE splitAt #-}

{-| Improper lens that splits after the longest consecutive group of bytes that
    satisfy the given predicate
-}
span
    :: Monad m
    => (Word8 -> Bool)
    -> Lens' (Producer ByteString m x)
             (Producer ByteString m (Producer ByteString m x))
span predicate k p0 = fmap join (k (go p0))
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

{-| Improper lens that splits after the longest consecutive group of bytes that
    fail the given predicate
-}
break
    :: Monad m
    => (Word8 -> Bool)
    -> Lens' (Producer ByteString m x)
             (Producer ByteString m (Producer ByteString m x))
break predicate = span (not . predicate)
{-# INLINABLE break #-}

{-| Improper lens that splits after the first group of matching bytes, as
    defined by the given equality predicate
-}
groupBy
    :: Monad m
    => (Word8 -> Word8 -> Bool)
    -> Lens' (Producer ByteString m r)
             (Producer ByteString m (Producer ByteString m r))
groupBy equals k p0 = fmap join (k (_groupBy p0))
  where
    -- _groupBy
    --     :: Monad m
    --     => Producer ByteString m r
    --     -> Producer ByteString m (Producer ByteString m r)
    _groupBy p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (return r)
            Right (bs, p') -> case (BS.uncons bs) of
                Nothing      -> _groupBy p'
                Just (w8, _) -> (yield bs >> p')^.span (equals w8)
{-# INLINABLE groupBy #-}

-- | Like 'groupBy', where the equality predicate is ('==')
group
    :: Monad m
    => Lens' (Producer ByteString m r)
             (Producer ByteString m (Producer ByteString m r))
group = groupBy (==)
{-# INLINABLE group #-}

{-| Improper lens that splits a 'Producer' after the first word

    Unlike 'words', this does not drop leading whitespace

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
word
    :: Monad m
    => Lens' (Producer ByteString m r)
             (Producer ByteString m (Producer ByteString m r))
word k p0 = fmap join (k (_word p0))
  where
    -- _word
    --     :: Monad m
    --     => Producer ByteString m r
    --     -> Producer ByteString m (Producer ByteString m r)
    _word p = do
        p' <- p^.span isSpaceWord8
        p'^.break isSpaceWord8
{-# INLINABLE word #-}

nl :: Word8
nl = fromIntegral (ord '\n')

{-| Improper lens that splits a 'Producer' after the first line

    Unlike 'lines', this does not consume the newline marker, which is stored
    within the inner 'Producer'

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
line
    :: Monad m
    => Lens' (Producer ByteString m r)
             (Producer ByteString m (Producer ByteString m r))
line = break (== nl)
{-# INLINABLE line #-}

-- | Intersperse a 'Word8' in between the bytes of the byte stream
intersperse
    :: Monad m
    => Word8 -> Getter' (Producer ByteString m r) (Producer ByteString m r)
intersperse w8 = to go0
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

-- | Improper isomorphism between a 'Producer' of 'ByteString's and 'Word8's
pack :: Monad m => Iso' (Producer Word8 m x) (Producer ByteString m x)
pack = Data.Profunctor.dimap _pack (fmap from)
  where
    -- _pack :: Monad m => Producer Word8 m x -> Producer ByteString m x
    _pack p = PG.folds step id done (p^.PG.chunksOf defaultChunkSize)

    step diffAs w8 = diffAs . (w8:)

    done diffAs = BS.pack (diffAs [])

    -- from :: Monad m => Producer ByteString m x -> Producer Word8 m x
    from p = for p (each . BS.unpack)
{-# INLINABLE pack #-}

{-| Group byte stream chunks into chunks of fixed length

    Note: This is the /only/ function in this API that concatenates
    'ByteString' chunks, which requires allocating new `ByteString`s
-}
chunksOf'
    :: (Monad m, Integral n)
    => n -> Getter' (Producer ByteString m r) (Producer ByteString m r)
chunksOf' n = to $ \p ->
    PG.folds
        (\diffBs bs -> diffBs . (bs:))
        id
        (\diffBs -> BS.concat (diffBs []))
        (p ^. chunksOf n)
{-# INLINABLE chunksOf' #-}

-- | Split a byte stream into 'FreeT'-delimited byte streams of fixed size
chunksOf
    :: (Monad m, Integral n)
    => n
    -> Lens' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
chunksOf n k p0 = fmap concats (k (go p0))
  where
    go p = PG.FreeT $ do
        x <- next p
        return $ case x of
            Left   r       -> PG.Pure r
            Right (bs, p') -> PG.Free $ do
                p'' <- (yield bs >> p')^.splitAt n
                return (go p'')
{-# INLINABLE chunksOf #-}

{-| Split a byte stream into groups separated by bytes that satisfy the
    predicate
-}
splitsWith
    :: Monad m
    => (Word8 -> Bool)
    -> Producer ByteString m x -> FreeT (Producer ByteString m) m x
splitsWith predicate p0 = PG.FreeT (go0 p0)
  where
    go0 p = do
        x <- next p
        case x of
            Left   r       -> return (PG.Pure r)
            Right (bs, p') ->
                if (BS.null bs)
                then go0 p'
                else go1 (yield bs >> p')
    go1 p = return $ PG.Free $ do
        p' <- p^.break predicate
        return $ PG.FreeT $ do
            x <- nextByte p'
            case x of
                Left   r       -> return (PG.Pure r)
                Right (_, p'') -> go1 p''
{-# INLINABLE splitsWith #-}

-- | Split a byte stream into groups separated by the given byte
splits
    :: Monad m
    => Word8
    -> Lens' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
splits w8 k p =
    fmap (PG.intercalates (yield (BS.singleton w8))) (k (splitsWith (w8 ==) p))
{-# INLINABLE splits #-}

{-| Isomorphism between a byte stream and groups of identical bytes using the
    supplied equality predicate
-}
groupsBy
    :: Monad m
    => (Word8 -> Word8 -> Bool)
    -> Lens' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
groupsBy equals k p0 = fmap concats (k (_groupsBy p0))
  where
    -- _groupsBy
    --     :: Monad m
    --     => (Word8 -> Word8 -> Bool)
    --     -> Producer ByteString m x
    --     -> FreeT (Producer ByteString m) m x
    _groupsBy p0' = PG.FreeT (go p0')
      where
        go p = do
            x <- next p
            case x of
                Left   r       -> return (PG.Pure r)
                Right (bs, p') -> case (BS.uncons bs) of
                    Nothing      -> go p'
                    Just (w8, _) -> do
                        return $ PG.Free $ do
                            p'' <- (yield bs >> p')^.span (equals w8)
                            return $ PG.FreeT (go p'')
{-# INLINABLE groupsBy #-}

-- | Like 'groupsBy', where the equality predicate is ('==')
groups
    :: Monad m
    => Lens' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
groups = groupsBy (==)
{-# INLINABLE groups #-}

{-| Improper isomorphism between a bytestream and its lines

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
lines
    :: Monad m
    => Iso' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
lines = Data.Profunctor.dimap _lines (fmap _unlines)
  where
    -- _lines
    --     :: Monad m
    --     => Producer ByteString m x -> FreeT (Producer ByteString m) m x
    _lines p0 = PG.FreeT (go0 p0)
      where
        go0 p = do
            x <- next p
            case x of
                Left   r       -> return (PG.Pure r)
                Right (bs, p') ->
                    if (BS.null bs)
                    then go0 p'
                    else return $ PG.Free $ go1 (yield bs >> p')
        go1 p = do
            p' <- p^.line
            return $ PG.FreeT $ do
                x  <- nextByte p'
                case x of
                    Left   r       -> return (PG.Pure r)
                    Right (_, p'') -> go0 p''

    -- _unlines
    --     :: Monad m
    --      => FreeT (Producer ByteString m) m x -> Producer ByteString m x
    _unlines = concats . PG.maps addNewline

    -- addNewline
    --     :: Monad m => Producer ByteString m r -> Producer ByteString m r
    addNewline p = p <* yield (BS.singleton nl)
{-# INLINABLE lines #-}

{-| Improper isomorphism between a bytestream and its words

    Note: This function is purely for demonstration purposes since it assumes a
    particular encoding.  You should prefer the 'Data.Text.Text' equivalent of
    this function from the upcoming @pipes-text@ library.
-}
words
    :: Monad m
    => Iso' (Producer ByteString m x) (FreeT (Producer ByteString m) m x)
words = Data.Profunctor.dimap _words (fmap _unwords)
  where
    -- _words
    --     :: Monad m
    --     => Producer ByteString m x -> FreeT (Producer ByteString m) m x
    _words p = PG.FreeT $ do
            x <- next (p >-> dropWhile isSpaceWord8)
            return $ case x of
                Left   r       -> PG.Pure r
                Right (bs, p') -> PG.Free $ do
                    p'' <- (yield bs >> p')^.break isSpaceWord8
                    return (_words p'')

    -- _unwords
    --     :: Monad m
    --     => FreeT (Producer ByteString m) m x -> Producer ByteString m x
    _unwords = PG.intercalates (yield $ BS.singleton $ fromIntegral $ ord ' ')
{-# INLINABLE words #-}

{- $parse
    The following parsing utilities are single-byte analogs of the ones found
    in @pipes-parse@.
-}

{- $reexports
    "Data.ByteString" re-exports 'ByteString'.

    "Data.Profunctor" re-exports 'Profunctor'.

    "Data.Word" re-exports 'Word8'.

    "Lens.Family" re-exports 'Phantom'.

    "Pipes.Parse" re-exports 'Parser'.

    "Pipes.Group" re-exports 'concats', 'intercalates', and 'FreeT' (the type).
-}
