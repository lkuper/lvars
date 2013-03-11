{-# LANGUAGE TypeFamilies, FlexibleInstances #-}
{-# LANGUAGE RankNTypes, NamedFieldPuns, BangPatterns,
             ExistentialQuantification, CPP
	     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wall -fno-warn-name-shadowing -fno-warn-unused-do-bind #-}

-- | This (experimental) module generalizes the Par monad to allow arbitrary LVars
-- (lattice variables) not just IVars.
-- 
-- This module exposes the internals of the @Par@ monad so that you
-- can build your own scheduler or other extensions.  Do not use this
-- module for purposes other than extending the @Par@ monad with new
-- functionality.

module LVarTraceInternal 
  (
    -- * LVar interface (for library writers):
--   runParIO, fork, LVar(..), newLV, getLV, putLV, liftIO,
   Par(), 
   
   -- * Example use case: Basic IVar ops.
--   runPar, IVar(), new, put, put_, get, spawn, spawn_, spawnP,

   -- * Example 2: Pairs (of Ivars).
--   newPair, putFst, putSnd, getFst, getSnd, 
   
   -- * Example 3: Monotonically growing sets.
--   ISet(), newEmptySet, newEmptySetWithCallBack, putInSet, waitForSet, waitForSetSize, consumeSet

  ) where

import           Control.Monad hiding (sequence, join)
import           Control.Applicative ((<$>))
import           Control.Concurrent hiding (yield)
import           Control.DeepSeq
import           Control.Applicative
import           Data.IORef
import qualified Data.Map as M
import qualified Data.Set as S
import           GHC.Conc hiding (yield)
import           System.IO.Unsafe (unsafePerformIO)
import           Prelude  hiding (mapM, sequence, head,tail)

import qualified Control.Monad.Par.Class as PC

-- From 'lattices' package:  Classes for join semi-lattices, top, bottom:
import Algebra.Lattice (BoundedJoinSemiLattice(..), JoinSemiLattice(..))

{-
------------------------------------------------------------------------------
-- IVars implemented on top of LVars:
------------------------------------------------------------------------------

-- TODO: newtype and hide the constructor:
-- type IVar a = LVar (IORef (IVarContents a))
newtype IVar a = IVar (LVar (IORef (IVarContents a)))
-- newtype IVarContents a = IVarContents { fromIVarContents :: Maybe a }

newtype IVarContents a = IVarContents (Maybe a)
fromIVarContents :: IVarContents a -> Maybe a
fromIVarContents (IVarContents x) = x

new :: Par (IVar a)
new = IVar <$> newLV (newIORef (IVarContents Nothing))

-- | read the value in a @IVar@.  The 'get' can only return when the
-- value has been written by a prior or parallel @put@ to the same
-- @IVar@.
get :: IVar a -> Par a
get (IVar lv@(LVar ref _ _)) = getLV lv poll
 where
   poll = fmap fromIVarContents $ readIORef ref

-- | put a value into a @IVar@.  Multiple 'put's to the same @IVar@
-- are not allowed, and result in a runtime error.
put_ :: IVar a -> a -> Par ()
put_ (IVar iv) elt = putLV iv putter
 where
   putter ref =
     atomicModifyIORef ref $ \ x ->
        case fromIVarContents x of
          Nothing -> (IVarContents (Just elt), ())
          Just  _ -> error "multiple puts to an IVar"

spawn :: NFData a => Par a -> Par (IVar a)
spawn p  = do r <- new;  fork (p >>= put r);   return r
              
spawn_ :: Par a -> Par (IVar a)
spawn_ p = do r <- new;  fork (p >>= put_ r);  return r

spawnP :: NFData a => a -> Par (IVar a)
spawnP a = spawn (return a)

put :: NFData a => IVar a -> a -> Par ()
put v a = deepseq a (put_ v a)

instance PC.ParFuture IVar Par where
  spawn_ = spawn_
  get = get

instance PC.ParIVar IVar Par where
  fork = fork  
  put_ = put_
  new = new
  
------------------------------------------------------------------------------
-- IPair implemented on top of LVars:
------------------------------------------------------------------------------

type IPair a b = LVar (IORef (IVarContents a),
                       IORef (IVarContents b))

newPair :: Par (IPair a b)
newPair = newLV $
          do r1 <- newIORef (IVarContents Nothing)
             r2 <- newIORef (IVarContents Nothing)
             return (r1,r2)

-- What is fromIVarContents?  If it's a function, I can't figure out
-- where it's defined.

putFst :: IPair a b -> a -> Par ()
putFst lv@(LVar (refFst, _) _ _) elt = putLV lv putter
  where
    -- putter takes the whole pair as an argument, but ignore it and
    -- just deal with refFst
    putter _ =
      atomicModifyIORef refFst $ \x -> 
      case fromIVarContents x of
        Nothing -> (IVarContents (Just elt), ())
        Just _  -> error "multiple puts to first element of IPair"
        
putSnd :: IPair a b -> b -> Par ()
putSnd lv@(LVar (_, refSnd) _ _) elt = putLV lv putter
  where
    -- putter takes the whole pair as an argument, but ignore it and
    -- just deal with refSnd
    putter _ =
      atomicModifyIORef refSnd $ \x -> 
      case fromIVarContents x of
        Nothing -> (IVarContents (Just elt), ())
        Just _  -> error "multiple puts to second element of IPair"

getFst :: IPair a b -> Par a
getFst iv@(LVar (ref1,_) _ _) = getLV iv poll
 where
   poll = fmap fromIVarContents $ readIORef ref1

getSnd :: IPair a b -> Par b
getSnd iv@(LVar (_,ref2) _ _) = getLV iv poll
 where
   poll = fmap fromIVarContents $ readIORef ref2

------------------------------------------------------------------------------
-- ISets and setmap implemented on top of LVars:
------------------------------------------------------------------------------

newtype ISet a = ISet (LVar (IORef (S.Set a)))

newEmptySet :: Par (ISet a)
newEmptySet = fmap ISet $ newLV$ newIORef S.empty

-- | Extended lambda-LVar (callbacks).  Create an empty set, but establish a callback
-- that will be invoked (in parallel) on each element added to the set.
newEmptySetWithCallBack :: forall a . Ord a => (a -> Par ()) -> Par (ISet a)
newEmptySetWithCallBack callb = fmap ISet $ newLVWithCallback io
 where -- Every time the set is updated we fork callbacks:
   io = do
     alreadyCalled <- newIORef S.empty
     contents <- newIORef S.empty   
     let fn :: IORef (S.Set a) -> IO Trace
         fn _ = do
           curr <- readIORef contents
           old <- atomicModifyIORef alreadyCalled (\set -> (curr,set))
           let new = S.difference curr old
           -- Spawn in parallel all new callbacks:
           let trcs = map runCallback (S.toList new)
           -- Would be nice if this were a balanced tree:           
           return (foldl Fork Done trcs)

         runCallback :: a -> Trace
         -- Run each callback with an etpmyt continuation:
         runCallback elem = runCont (callb elem) (\_ -> Done)
         
     return (contents, fn)

-- | Put a single element in the set.
putInSet :: Ord a => a -> ISet a -> Par () 
putInSet elem (ISet lv) = putLV lv putter
  where
    putter ref = atomicModifyIORef ref (\set -> (S.insert elem set, ()))

-- | Wait for the set to contain a specified element.
waitForSet :: Ord a => a -> ISet a -> Par ()
waitForSet elem (ISet lv@(LVar ref _ _)) = getLV lv getter
  where
    getter = do
      set <- readIORef ref
      case S.member elem set of
        True  -> return (Just ())
        False -> return (Nothing)

-- | Wait on the SIZE of the set, not its contents.
waitForSetSize :: Int -> ISet a -> Par ()
waitForSetSize sz (ISet lv@(LVar ref _ _)) = getLV lv getter
  where
    getter = do
      set <- readIORef ref
      if S.size set >= sz
         then return (Just ())
         else return Nothing     

-- | Get the exact contents of the set.  Using this may cause your program exhibit a
-- limited form of non-determinism.  It will never return the wrong answer, but it
-- may include synchronization bugs that can (non-deterministically) cause exceptions.
consumeSet :: ISet a -> Par (S.Set a)
consumeSet (ISet lv) = consumeLV lv readIORef

-}
------------------------------------------------------------------------------
-- Underlying LVar representation:
------------------------------------------------------------------------------

-- | An LVar is a box containing a purely functional data structure.
-- 
-- This implementation cannot provide scalable LVars (e.g. a concurrent hashmap),
-- rather accesses to a single LVar will contend.  
data LVar a = LVar {
  -- TODO: consider MutVar# 
  lvstate :: {-# UNPACK #-} !(IORef (LVarContents a)),
  callback :: Maybe (a -> Trace)
}

data LVarContents a = LVarContents {
    current :: a,
    blocked :: [a -> Maybe Trace]
 }

-- Return the old value.  Could replace with a true atomic op.
atomicIncr :: IORef Int -> IO Int
atomicIncr cntr = atomicModifyIORef cntr (\c -> (c+1,c))

type UID = Int

uidCntr :: IORef UID
uidCntr = unsafePerformIO (newIORef 0)

getUID :: IO UID
getUID =  atomicIncr uidCntr


-- ---------------------------------------------------------------------------
-- Generic scheduler with LVars:
-- ---------------------------------------------------------------------------

newtype Par a = Par {
    runCont :: (a -> Trace) -> Trace
}

instance Functor Par where
    fmap f m = Par $ \c -> runCont m (c . f)

instance Monad Par where
    return a = Par ($ a)
    m >>= k  = Par $ \c -> runCont m $ \a -> runCont (k a) c

instance Applicative Par where
   (<*>) = ap
   pure  = return

-- | Trying this using only parametric polymorphism:
data Trace =
             forall a b . Get (LVar a) (a -> (Maybe b)) (b -> Trace)
           | forall a . JoinSemiLattice a => Put (LVar a) a Trace
           | forall a . New a (LVar a -> Trace)
           | Fork Trace Trace
           | Done
           | DoIO (IO ()) Trace
           | Yield Trace

           -- Destructively consume the value (limited nondeterminism):
           | forall a b . Consume (LVar a) (a -> Trace)

           -- The callback (unsafely) is scheduled when there is ANY change.  It does
           -- NOT get a snapshot of the (continuously mutating) state, just the right
           -- to read whatever it can.
           | forall a . NewWithCallBack a (a -> Trace) (LVar a -> Trace)

-- | The main scheduler loop.
sched :: Bool -> Sched -> Trace -> IO ()
sched _doSync queue t = loop t
 where

  -- -- Try to wake it up and remove from the wait list.  Returns true if this was the
  -- -- call that actually removed the entry.
  -- tryWake (Poller fn flag) waitmp uid = do
  --   b <- atomicModifyIORef flag (\b -> (True,b)) -- CAS would work.
  --   case b of
  --     True -> return False -- Already woken.
  --     False -> do atomicModifyIORef waitmp $ \mp -> (M.delete uid mp, ())
  --                 return True 
        
  loop origt = case origt of
    New init cont -> do
      ref <- newIORef$ LVarContents init []
      loop (cont (LVar ref Nothing))

    NewWithCallBack init cb cont -> do
      ref <- newIORef$ LVarContents init []
      loop (cont$ LVar ref (Just cb))

    Get (LVar ref cb) thresh cont -> do
      -- Tradeoff, we could do a plain read before the atomicModifyIORef.  But that
      -- would require evaluating the threshold function TWICE if we need to block.
      -- (Which is potentially more expensive than in the plain IVar case.)
      -- e <- readIORef ref
      let thisCB x = fmap cont $ thresh x
      r <- atomicModifyIORef ref $ \ st@(LVarContents a ls) ->
        case thresh a of
          Just b  -> (st, loop (cont b))
          Nothing -> (LVarContents a (thisCB:ls), reschedule queue)
      r

    Consume (LVar ref cb) cont -> do
      -- HACK!  We know nothing about the type of state.  But we CAN destroy it
      -- to prevent any future access:
      a <- atomicModifyIORef ref (\(LVarContents a _) ->
                                   (error "attempt to touch LVar after Consume operation!", a))
      loop (cont a)

    Put (LVar ref cb) new tr  -> do
      cs <- atomicModifyIORef ref $ \e -> case e of
              LVarContents a ls ->
                let new' = join a new
                    (ls',woken) = loop ls [] []
                    loop [] f w = (f,w)
                    loop (hd:tl) f w =
                      case hd new of
                        Just trc -> loop tl f (trc:w)
                        Nothing  -> loop tl (hd:f) w 
                in 
                (LVarContents new' ls', woken)
      mapM_ (pushWork queue) cs
      loop tr              


    Fork child parent -> do
         pushWork queue parent -- "Work-first" policy.
         loop child
         -- pushWork queue child -- "Help-first" policy.  Generally bad.
         -- loop parent

    Done ->
         if _doSync
	 then reschedule queue
         -- We could fork an extra thread here to keep numCapabilities workers
         -- even when the main thread returns to the runPar caller...
         else do putStrLn " [par] Forking replacement thread..\n"
                 forkIO (reschedule queue); return ()
         -- But even if we don't we are not orphaning any work in this
         -- threads work-queue because it can be stolen by other threads.
         --	 else return ()

    DoIO io t -> io >> loop t

    Yield parent -> do 
        -- Go to the end of the worklist:
        let Sched { workpool } = queue
        -- TODO: Perhaps consider Data.Seq here.
	-- This would also be a chance to steal and work from opposite ends of the queue.
        atomicModifyIORef workpool $ \ts -> (ts++[parent], ())
	reschedule queue


-- | Process the next item on the work queue or, failing that, go into
--   work-stealing mode.
reschedule :: Sched -> IO ()
reschedule queue@Sched{ workpool } = do
  e <- atomicModifyIORef workpool $ \ts ->
         case ts of
           []      -> ([], Nothing)
           (t:ts') -> (ts', Just t)
  case e of
    Nothing -> steal queue
    Just t  -> sched True queue t

-- RRN: Note -- NOT doing random work stealing breaks the traditional
-- Cilk time/space bounds if one is running strictly nested (series
-- parallel) programs.

-- | Attempt to steal work or, failing that, give up and go idle.
steal :: Sched -> IO ()
steal _ = return ()
steal q@Sched{ idle, scheds, no=my_no } = do
  -- printf "cpu %d stealing\n" my_no
  go scheds
  where
    go [] = do m <- newEmptyMVar
               r <- atomicModifyIORef idle $ \is -> (m:is, is)
               if length r == numCapabilities - 1
                  then do
                     -- printf "cpu %d initiating shutdown\n" my_no
                     mapM_ (\m -> putMVar m True) r
                  else do
                    done <- takeMVar m
                    if done
                       then do
                         -- printf "cpu %d shutting down\n" my_no
                         return ()
                       else do
                         -- printf "cpu %d woken up\n" my_no
                         go scheds
    go (x:xs)
      | no x == my_no = go xs
      | otherwise     = do
         r <- atomicModifyIORef (workpool x) $ \ ts ->
                 case ts of
                    []     -> ([], Nothing)
                    (x:xs) -> (xs, Just x)
         case r of
           Just t  -> do
              -- printf "cpu %d got work from cpu %d\n" my_no (no x)
              sched True q t
           Nothing -> go xs


-- | If any worker is idle, wake one up and give it work to do.
pushWork :: Sched -> Trace -> IO ()
pushWork Sched { workpool, idle } t = do
  atomicModifyIORef workpool $ \ts -> (t:ts, ())
  idles <- readIORef idle
  when (not (null idles)) $ do
    r <- atomicModifyIORef idle (\is -> case is of
                                          [] -> ([], return ())
                                          (i:is) -> (is, putMVar i False))
    r -- wake one up

data Sched = Sched
    { no       :: {-# UNPACK #-} !Int,
      workpool :: IORef [Trace],
      idle     :: IORef [MVar Bool],
      scheds   :: [Sched] -- Global list of all per-thread workers.
    }

-- Forcing evaluation of a LVar is fruitless.
instance NFData (LVar a) where
  rnf _ = ()

{-

{-# INLINE runPar_internal #-}
runPar_internal :: Bool -> Par a -> IO a
runPar_internal _doSync x = do
   workpools <- replicateM numCapabilities $ newIORef []
   idle <- newIORef []
   let states = [ Sched { no=x, workpool=wp, idle, scheds=states }
                | (x,wp) <- zip [0..] workpools ]

#if __GLASGOW_HASKELL__ >= 701 /* 20110301 */
    --
    -- We create a thread on each CPU with forkOnIO.  The CPU on which
    -- the current thread is running will host the main thread; the
    -- other CPUs will host worker threads.
    --
    -- Note: GHC 7.1.20110301 is required for this to work, because that
    -- is when threadCapability was added.
    --
   (main_cpu, _) <- threadCapability =<< myThreadId
#else
    --
    -- Lacking threadCapability, we always pick CPU #0 to run the main
    -- thread.  If the current thread is not running on CPU #0, this
    -- will require some data to be shipped over the memory bus, and
    -- hence will be slightly slower than the version above.
    --
   let main_cpu = 0
#endif

   m <- newEmptyMVar
   forM_ (zip [0..] states) $ \(cpu,state) ->
        forkOnIO cpu $
          if (cpu /= main_cpu)
             then reschedule state
             else sched _doSync state $ runCont (do x' <- x; liftIO (putMVar m x')) (const Done)
   takeMVar m


runPar :: Par a -> a
runPar = unsafePerformIO . runPar_internal True

-- | A version that avoids an internal `unsafePerformIO` for calling
--   contexts that are already in the `IO` monad.
runParIO :: Par a -> IO a
runParIO = runPar_internal True

-- | An asynchronous version in which the main thread of control in a
-- Par computation can return while forked computations still run in
-- the background.  
runParAsync :: Par a -> a
runParAsync = unsafePerformIO . runPar_internal False

-- -----------------------------------------------------------------------------
-- Basic stuff:

-- Not in 6.12: {- INLINABLE fork -}
{-# INLINE fork #-}
fork :: Par () -> Par ()
fork p = Par $ \c -> Fork (runCont p (\_ -> Done)) (c ())


-- -----------------------------------------------------------------------------

-- | Internal operation.  Creates a new @LVar@ with an initial value
newLV :: IO lv -> Par (LVar lv)
newLV init = Par $ New init

newLVWithCallback :: IO (lv, lv -> IO Trace) -> Par (LVar lv)
newLVWithCallback = Par .  NewWithCallBack
                    

-- | Internal operation.  Test if the LVar satisfies the given threshold.
getLV :: LVar a -> (IO (Maybe b)) -> Par b
getLV lv poll = Par $ Get lv poll

-- | Internal operation.  Modify the LVar.  Had better be monotonic.
putLV :: LVar a -> (a -> IO ()) -> Par ()
putLV lv fn = Par $ \c -> Put lv fn (c ())

-- | Internal operation. Destructively consume the LVar, yielding access to its precise state.
consumeLV :: LVar a -> (a -> IO b) -> Par b
consumeLV lv extractor = Par $ Consume lv extractor

liftIO :: IO () -> Par ()
liftIO io = Par $ \c -> DoIO io (c ())

-}