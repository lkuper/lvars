{-# LANGUAGE TemplateHaskell, CPP, ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}

-- | Core tests for the LVish scheduler and basic futures/IVars.
--   TODO: other data structure tests should be factored out of here.

module LVishAndIVar(tests, runTests) where

import Test.Framework.Providers.HUnit 
import Test.Framework (Test, defaultMain, testGroup)
-- [2013.09.26] Temporarily disabling template haskell due to GHC bug discussed here:
--   https://github.com/rrnewton/haskell-lockfree/issues/10
import Test.Framework.TH (testGroupGenerator)

import Test.HUnit (Assertion, assertEqual, assertBool, Counts(..))
import qualified Test.HUnit as HU
import Control.Applicative
import Control.Monad
import Control.Concurrent
import Control.Concurrent.MVar
import GHC.Conc
import Data.List (isInfixOf, intersperse)
import qualified Data.Vector as V
import qualified Data.Set as S
import Data.IORef
import Data.Time.Clock
import System.Environment (getArgs)
import System.IO
import System.Exit
import System.Random

import Control.Exception (catch, evaluate, SomeException)

import Data.Traversable (traverse)
import qualified Data.Set as S
import qualified Data.Map as M
import Data.Word

  -- TODO: Remove most of this!  This file should not tests LVars other than IVars:

import qualified Data.LVar.Generic as G
import qualified Data.LVar.NatArray as NA
import Data.LVar.PureSet as IS
import Data.LVar.PureMap as IM

import qualified Data.LVar.SLMap as SM
import qualified Data.LVar.SLSet as SS
import Data.LVar.Memo  as Memo

import qualified Data.LVar.IVar as IV
import qualified Data.LVar.IStructure as ISt
import qualified Data.LVar.Pair as IP

import Control.LVish
import Control.LVish.DeepFrz (DeepFrz(..), Frzn, Trvrsbl, runParThenFreeze, runParThenFreezeIO)
import qualified Control.LVish.Internal as I
import Control.LVish.SchedIdempotent (liftIO, dbgLvl, forkWithExceptions)
import qualified Control.LVish.SchedIdempotent as L

import qualified Data.Concurrent.SNZI as SNZI
import qualified Data.Concurrent.LinkedMap as LM
import qualified Data.Concurrent.SkipListMap as SLM

import TestHelpers as T

runTests :: IO ()
runTests = defaultMain [tests]

-- SADLY, this use of template-Haskell, together with the atomic-primops dependency,
-- triggers a GHC linking bug:
tests :: Test
tests = $(testGroupGenerator)

--------------------------------------------------------------------------------

-- Disabling thread-variation due to below bug:

-- EEK!  Just got this [2013.06.27]:
-- 
-- unit-tests.exe: internal error: wakeup_gc_threads
--     (GHC version 7.6.3 for x86_64_unknown_linux)
--     Please report this as a GHC bug:  http://www.haskell.org/ghc/reportabug
-- Aborted (core dumped)

case_v0 :: HU.Assertion
case_v0 = do res <- v0
             HU.assertEqual "useless fork" (4::Int) res
v0 = runParIO $ do i <- IV.new; fork (return ()); IV.put i 4; IV.get i


case_v1a :: Assertion
case_v1a = assertEqual "fork put" (4::Int) =<< v1a
v1a :: IO Int
v1a = runParIO $ do i<-IV.new; fork (IV.put i 4); IV.get i

case_v1b :: Assertion
case_v1b = do ls <- v1b
              case length ls of
                0 -> return () -- Ok, i guess debugging is off.
                1 -> return () 
                _ -> error $ "Wrong number of log messages: \n" ++ concat (intersperse "\n" ls)

-- | In this sequential case there should be no data-race, and thus no duplication of the callback.
v1b :: IO [String]
v1b = do let tag = "callback on ivar "
         (logs,_) <- runParLogged $ do
                       i <- IV.new
                       IV.put i (3::Int)                       
                       IV.whenFull Nothing i (\x -> logStrLn$ tag++show x)
                       IV.put i 3
                       IV.put i 3
                       return ()
         mapM_ putStrLn logs
         return (filter (isInfixOf tag) logs)

-- v1c

case_v2a :: Assertion
case_v2a = v2a >>= assertEqual "put 10 in & wait"
          (S.fromList [1..10] :: S.Set Int)

-- [2013.06.27] getting thread-blocked-indefinitely errors:
v2a :: IO (S.Set Int)
v2a = runParIO $
     do s <- IS.newEmptySet
        mapM_ (\n -> fork $ IS.insert n s) [1..10]
        IS.waitSize 10 s 
        IS.freezeSet s

-- | This version uses a fork-join so it doesn't need the waitSize:
case_v2b :: Assertion
case_v2b = v2b >>= assertEqual "t2 with spawn instead of fork"
           (S.fromList [1..10] :: S.Set Int)
           
v2b :: IO (S.Set Int)
v2b = runParIO $
     do s   <- IS.newEmptySet
        ivs <- mapM (\n -> IV.spawn_ $ IS.insert n s) [1..10]
        mapM_ IV.get ivs -- Join point.
        IS.freezeSet s

-- FIMXE:

-- | This version uses deep freeze.        
case_v2c :: Assertion
case_v2c = assertEqual "t2 with spawn instead of fork"
             (S.fromList [1..10] :: S.Set Int)
             (IS.fromISet v2c)
             
-- v2c :: S.Set Int
v2c :: IS.ISet Frzn Int
v2c = -- IS.fromISet $
      runParThenFreeze par
  where
    par :: Par Det s (IS.ISet s Int)
    par = 
     do s   <- IS.newEmptySet 
        ivs <- mapM (\n -> IV.spawn_ $ IS.insert n s) [1..10::Int]
        mapM_ IV.get ivs -- Join point.
        return s

escape01 :: IV.IVar Frzn Int
escape01 = runParThenFreeze $ do v <- IV.new; IV.put v (3::Int); return v

-- | This is VERY BAD:
escape01B :: Par d Frzn String
escape01B = 
            do IV.put escape01 (4::Int)
               return "uh oh"

-- | [2013.10.06] Fixed this by requiring a SPECIFIC type, NonFrzn.
-- major_bug :: String
-- major_bug = runParThenFreeze escape01B
               
-- | Simple callback test.
-- case_v3a :: Assertion
-- case_v3a = v3a >>= assertEqual "simple callback test"
--           (S.fromList [10,20,30,40,50,60,70,80,90,100] :: S.Set Int)

-- [2013.06.27] This is failing just occasionally with a multiple-put:
v3a :: IO (S.Set Int)          
v3a = runParIO $
     do s1 <- IS.newEmptySet
        s2 <- IS.newEmptySet
        let fn e = IS.insert (e*10) s2
        IS.withCallbacksThenFreeze s1 fn $ do
          -- Populate the first set:
          mapM_ (\n -> fork $ IS.insert n s1) [1..10]        
          -- We never read out of s1 directly.  Instead, writes to s1 trigger the
          -- callback 'fn' to run, with the element written to s2.  So eventually,
          -- ten elements are written to s2.
          IS.waitSize 10 s2
          IS.freezeSet s2

case_v3b :: Assertion
case_v3b = v3b >>= assertEqual "simple callback test"
          (S.fromList [10,20,30,40,50,60,70,80,90,100] :: S.Set Int)
          
v3b :: IO (S.Set Int)          
v3b = runParIO $
     do s1 <- IS.newEmptySet
        s2 <- IS.newEmptySet
        let fn e = IS.insert (e*10) s2
        IS.withCallbacksThenFreeze s1 fn $ do
          -- Populate the first set:
          mapM_ (\n -> IS.insert n s1) [1..10]
          -- Because we filled s1 sequentially, we know it is full at this point.
          -- (If the above were forked we would need a finish/asnyc style construct)
          
        -- After all of s1's callbacks are finished executing, s2 is full:
        IS.freezeSet s2


-- | An under-synchronized test.  This should always return the same
-- result OR throw an exception.  In this case it should always return
-- a list of 10 elements, or throw an exception.
case_i3c :: Assertion
case_i3c = do 
  allowSomeExceptions ["Attempt to change a frozen LVar"] $ 
    do x <- i3c
       assertEqual "under-synchronized passed through"
      	           (S.fromList [10,20..100] :: S.Set Int) x
  return ()
    
i3c :: IO (S.Set Int)
i3c = runParIO $
     do s1 <- IS.newEmptySet
        s2 <- IS.newEmptySet
        let fn e = IS.insert (e*10) s2
        IS.withCallbacksThenFreeze s1 fn $ do
          mapM_ (\n -> fork $ IS.insert n s1) [1..10]          
          IS.waitSize 1 s2 -- Not ENOUGH synchronization!
          IS.freezeSet s2
          -- If this ^ freeze occurs *before* all the puts have happened,
          -- the a put happening after it will throw an exception.  If,
          -- on the other hand, it occurs after they've all happened,
          -- then we won't notice that anything is wrong and we'll get
          -- the same result we would have in case_v3.

-- FIXME: currently if run enough times, i3c can get the following failure:
-- I think we need to use full Async's so the cancellation goes both ways:

   -- Main:
   -- Exception inside child thread "worker thread", ThreadId 12: Attempt to change a frozen LVar
   -- Exception inside child thread "worker thread", ThreadId 9: Attempt to change a frozen LVar
   -- Exception inside child thread "worker thread", ThreadId 11: Attempt to change a frozen LVar
   -- test-lvish: Attempt to change a frozen LVar
   -- Exception inside child thread "worker thread", ThreadId 10: thread blocked indefinitely in an MVar operation


case_v3d :: Assertion
case_v3d = assertEqual "test of parallelism in freezeSetAfter"
              (S.fromList [1..5]) =<<  v3d

-- | This test has interdependencies between callbacks (that are launched on
-- already-present data), which forces these to be handled in parallel.
v3d :: IO (S.Set Int)
v3d = runParIO $ 
     do s1 <- IS.newFromList [1..5]
        s2 <- IS.newEmptySet
        IS.freezeSetAfter s1 $ \ elm -> do
          let dep = case elm of
                      1 -> Just 2
                      2 -> Just 3
                      3 -> Nothing -- Foil either left-to-right or right-to-left
                      4 -> Just 3
                      5 -> Just 4
          case dep of
            Nothing -> logStrLn $ "  [Invocation "++show elm++"] has no dependencies, running... "
            Just d -> do logStrLn $ "  [Invocation "++show elm++"] waiting on "++show dep
                         IS.waitElem d s2
                         logStrLn $ "  [Invocation "++show elm++"] dependency satisfied! "
          IS.insert elm s2 
        logStrLn " [freezeSetAfter completed] "
        freezeSet s2

case_v3e :: Assertion
case_v3e = assertEqual "test of parallelism in forEachHP"
              (S.fromList [1..5]) =<<  v3e

-- | Same as v3d but for forEachHP
v3e :: IO (S.Set Int)
v3e = runParIO $ IS.freezeSet =<<
     do s1 <- IS.newFromList [1..5]
        s2 <- IS.newEmptySet
        hp <- newPool
        IS.forEachHP (Just hp) s1 $ \ elm -> do
          let dep = case elm of
                      1 -> Just 2
                      2 -> Just 3
                      3 -> Nothing -- Foil either left-to-right or right-to-left
                      4 -> Just 3
                      5 -> Just 4
          case dep of
            Nothing -> logStrLn $ "  [Invocation "++show elm++"] has no dependencies, running... "
            Just d -> do logStrLn $ "  [Invocation "++show elm++"] waiting on "++show dep
                         IS.waitElem d s2
                         logStrLn $ "  [Invocation "++show elm++"] dependency satisfied! "
          IS.insert elm s2
        quiesce hp
        logStrLn " [quiesce completed] "
        return s2

-- RRN: Currently we have a policy where leaving the seen with running threads is
-- disallowed, but blocked ones are tolerated.
case_i3f :: Assertion
case_i3f = exceptionOrTimeOut 0.3 ["test switched off"] i3f
#ifdef NO_DANGLING_THREADS
-- | A test to make sure that we get an error when we block on an unavailable ivar.
i3f :: IO ()
i3f = runParIO$ do
  iv <- IV.new
  fork $ do IV.get iv
            logStrLn "Unblocked!  Shouldn't see this."
            return ()
  return ()
#else 
i3f = error "test switched off"
#endif

case_i3g :: Assertion
case_i3g = exceptionOrTimeOut 0.3 [] i3g
-- | A still-running worker thread should NOT be allowed, because it may do a put that causes an exception.
i3g :: IO Word8
i3g = runParIO$ do
  iv <- IV.new
  fork $ do let loop !ls = loop [1 .. length ls]
            loop [1..10]
  return 9


case_v7a :: Assertion
case_v7a = assertEqual "basic imap test"
           (M.fromList [(1,1.0),(2,2.0),(3,3.0),(100,100.1),(200,201.1)]) =<<
           v7a

v7a :: IO (M.Map Int Float)
v7a = runParIO $ IM.freezeMap =<<
  do mp <- IM.newEmptyMap
     fork $ do IM.waitSize 3 mp
               IM.insert 100 100.1 mp
     fork $ do IM.waitValue 100.1 mp
               v <- IM.getKey 1 mp
               IM.insert 200 (200.1 + v) mp
     IM.insert 1 1 mp
     IM.insert 2 2 mp
     logStrLn "[v7a] Did the first two puts.."
     I.liftIO$ threadDelay 1000
     IM.insert 3 3 mp
     logStrLn "[v7a] Did the first third put."
     IM.waitSize 5 mp
     return mp

-- [2013.08.05] RRN: Observing nondeterministic blocked-indefinitely
-- exception here.
case_i7b :: Assertion
case_i7b = do 
  allowSomeExceptions ["Multiple puts"] $ 
    assertEqual "racing insert and modify"
                 (M.fromList [(1,S.fromList [3.33]),
                              (2,S.fromList [0.11,4.44])]) =<<
                i7b
  return ()

-- | A quasi-deterministic example.
i7b :: IO (M.Map Int (S.Set Float))
-- Do we need a "deep freeze" that freezes nested structures?
i7b = runParIO $ do
  mp <- IM.newEmptyMap
  s1 <- IS.newEmptySet
  s2 <- IS.newEmptySet
  IS.insert 0.11 s2
  f1 <- IV.spawn_ $ do IM.insert 1 s1 mp 
                       IM.insert 2 s2 mp
  f2 <- IV.spawn_ $ do s <- IM.getKey 1 mp
                       IS.insert 3.33 s
  -- RACE: this modify is racing with the insert of s2:
  IM.modify mp 2 IS.newEmptySet (IS.insert 4.44) 

  IV.get f1; IV.get f2
  mp2 <- IM.freezeMap mp
  traverse IS.freezeSet mp2

case_v7c :: Assertion
case_v7c = assertEqual "imap test - racing modifies"
           (M.fromList [(1,S.fromList [3.33]),
                        (2,S.fromList [4.44]),
                        (3,S.fromList [5.55,6.6])]) =<<
           v7c

-- | This example is valid because two modifies may race.
v7c :: IO (M.Map Int (S.Set Float))
-- Do we need a "deep freeze" that freezes nested structures?
v7c = runParIO $ do
  mp <- IM.newEmptyMap
  s1 <- IS.newEmptySet
  f1 <- IV.spawn_ $ IM.insert 1 s1 mp 
  f2 <- IV.spawn_ $ do s <- IM.getKey 1 mp
                       IS.insert 3.33 s
  IM.modify mp 2 IS.newEmptySet (IS.insert 4.44)
  f3 <- IV.spawn_ $ IM.modify mp 3 IS.newEmptySet (IS.insert 5.55)
  f4 <- IV.spawn_ $ IM.modify mp 3 IS.newEmptySet (IS.insert 6.6)
  -- No easy way to wait on the total size of all contained sets...
  -- 
  -- Need a barrier here.. should have a monad-transformer that provides cilk "sync"
  -- Global quiesce is convenient too..
  IV.get f1; IV.get f2; IV.get f3; IV.get f4
  mp2 <- IM.freezeMap mp
  traverse IS.freezeSet mp2

--------------------------------------------------------------------------------
-- Higher level derived ops
--------------------------------------------------------------------------------  

case_v8a :: Assertion
case_v8a = assertEqual "simple cartesian product test"
           (S.fromList
            [(1,'a'),(1,'b'),(1,'c'),
             (2,'a'),(2,'b'),(2,'c'),
             (3,'a'),(3,'b'),(3,'c')])
           =<< v8a

-- v8a :: IO (S.Set (Integer, Char))
v8a :: IO (S.Set (Integer, Char))
v8a = runParIO $ do
  s1 <- IS.newFromList [1,2,3]
  s2 <- IS.newFromList ['a','b']
  logStrLn " [v8a] now to construct cartesian product..."
  h  <- newPool
  s3 <- IS.cartesianProdHP (Just h) s1 s2
  logStrLn " [v8a] cartesianProd call finished... next quiesce"
  IS.forEach s3 $ \ elm ->
    logStrLn$ " [v8a]   Got element: "++show elm
  IS.insert 'c' s2
  quiesce h
  logStrLn " [v8a] quiesce finished, next freeze::"
  freezeSet s3

case_v8b :: Assertion
case_v8b = assertEqual "3-way cartesian product"
           (S.fromList
            [[1,40,101],[1,40,102],  [1,50,101],[1,50,102],
             [2,40,101],[2,40,102],  [2,50,101],[2,50,102]]
            )
           =<< v8b

v8b :: IO (S.Set [Int])
v8b = runParIO $ do
  hp <- newPool
  s1 <- IS.newFromList [1,2]
  s2 <- IS.newFromList [40,50]
    -- (hp,s3) <- IS.traverseSetHP Nothing (return . (+100)) s1
  s3 <- IS.traverseSetHP    (Just hp) (return . (+100)) s1
  s4 <- IS.cartesianProdsHP (Just hp) [s1,s2,s3]
  IS.forEachHP (Just hp) s4 $ \ elm ->
    logStrLn $ " [v8b]   Got element: "++show elm
  -- [2013.07.03] Confirmed: this makes the bug(s) go away:  
  -- liftIO$ threadDelay$ 100*1000
  quiesce hp
  logStrLn " [v8b] quiesce finished, next freeze::"
  freezeSet s4

case_v8c :: Assertion
case_v8c = assertEqual "forEachHP on maps"
           (M.fromList [(1,101),(2,102)] ) =<< v8c

-- | Similar test with Maps instead of Sets.
v8c :: IO (M.Map Int Int)
v8c = runParIO $ do
  hp <- newPool
  m1 <- IM.newFromList [(1,1),(2,2)]
  m2 <- newEmptyMap
  let cb k v = do logStrLn$" [v8c]  Inside callback for Map.. key="++show k
                  IM.insert k (v+100) m2
  IM.forEachHP (Just hp) m1 cb 
  logStrLn " [v8c] Everything set up; about to quiesce..."
  quiesce hp
  logStrLn " [v8c] quiesce finished, next freeze:"
  freezeMap m2


case_v8d :: Assertion
case_v8d = assertEqual "union on maps"
           (M.fromList [(1,101),(2,102),(40,40),(50,50)] )
             =<< v8d
v8d :: IO (M.Map Int Int)
v8d = runParIO $ do
  hp <- newPool
  logStrLn " [v8d] Got a new pool..."  
  m1 <- IM.newFromList [(1,1),(2,2)]
  m2 <- IM.newFromList [(40,40),(50,50)]
  logStrLn " [v8d] Got two fresh maps..."
  let cb k v = do logStrLn$" [v8d]  Inside callback for traverse.. key="++show k
                  return (v+100)
  m3 <- IM.traverseMapHP (Just hp) cb m1
  m4 <- IM.unionHP       (Just hp) m2 m3
  IM.forEachHP (Just hp) m4 $ \ k elm ->
    logStrLn $ " [v8d]   Got element: "++show (k,elm)
  logStrLn " [v8d] Everything set up; about to quiesce..."
  quiesce hp
--  quiesceAll  
  logStrLn " [v8d] quiesce finished, next freeze::"
  freezeMap m4

--------------------------------------------------------------------------------
-- Looping constructs
--------------------------------------------------------------------------------

case_lp01 :: Assertion
case_lp01 = assertEqual "parForSimple test" "done" =<< lp01
lp01 = runParIO$ do
  logStrLn " [lp01] Starting parForSimple loop..."
  x <- IV.new 
  parForSimple (0,10) $ \ ix -> do
    logStrLn$ " [lp01]  iter "++show ix
    when (ix == 9)$ IV.put x "done"
  IV.get x

case_lp02 :: Assertion
case_lp02 = assertEqual "parForL test" "done" =<< lp02
lp02 = runParIO$ do
  logStrLn " [lp02] Starting parForL loop..."
  x <- IV.new 
  parForL (0,10) $ \ ix -> do
    logStrLn$ " [lp02]  iter "++show ix
    when (ix == 9)$ IV.put x "done"
  logStrLn$ " [lp02] after loop..."
  IV.get x

-- [2013.08.05] RRN: I'm seeing this hang sometimes.  It live-locks
-- burning CPU.  (But only 170% CPU with -N4.)  Hmm, I can't get it to
-- freeze running BY ITSELF, however.  In fact I can't get the problem
-- while running just the "lp" tests.  I can get the problem running
-- just 'v' tests and even just 'v9' tests.
case_lp03 :: Assertion
case_lp03 = assertEqual "parForTree test" "done" =<< lp03
lp03 = runParIO$ do
  logStrLn " [lp03] Starting parForTree loop..."
  x <- IV.new 
  parForTree (0,10) $ \ ix -> do
    logStrLn$ " [lp03]  iter "++show ix
    when (ix == 9)$ IV.put x "done"
  logStrLn$ " [lp03] after loop..."
  IV.get x

case_lp04 :: Assertion
case_lp04 = assertEqual "parForTree test" "done" =<< lp04
lp04 = runParIO$ do
  logStrLn " [lp04] Starting parForTiled loop..."
  x <- IV.new 
  parForTiled 16 (0,10) $ \ ix -> do
    logStrLn$ " [lp04]  iter "++show ix
    when (ix == 9)$ IV.put x "done"
  logStrLn$ " [lp04] after loop..."
  IV.get x

--------------------------------------------------------------------------------
-- TEMPLATE HASKELL BUG? -- if we have *block* commented case_foo decls, it detects
-- those when it shouldn't:
--------------------------------------------------------------------------------

-- -- | Simple test of pairs.
-- case_v4 :: Assertion
-- case_v4 = v4 >>= assertEqual "simple-pair" (3, "hi") 

-- v4 :: IO (Int,String)
-- v4 = runParIO $
--      do p <- newPair
--         putFst p 3
--         putSnd p "hi"        
--         x <- getFst p
--         y <- getSnd p
--         return (x,y)

-- -- | This program should throw an exception due to multiple puts.
-- case_i5a :: Assertion
-- case_i5a = assertException ["Multiple puts to an IVar!"] i5a

-- i5a :: IO Int
-- i5a = runParIO (
--      do p <- newPair
--         putFst p 3
--         putSnd p "hi"
--         putSnd p "there"        
--         getFst p)

-- -- | Another exception due to multiple puts.  This tests whether the scheduler waits
-- -- around for a trailing (errorful) computation that is not on the main thread.
-- case_i5b :: Assertion
-- case_i5b = assertException ["Multiple puts to an IVar!"] i5b

-- i5b = 
--   runParIO $
--      do p <- newPair
--         putFst p 3
--         putSnd p "hi"
--         fork $ do waste_time
--                   putSnd p "there"
--         -- There's no 'consume' here; so we should really just get a
--         -- "Multiple puts to an IVar!" exception.
--         getSnd p

-- -- | Similar to 5b but with the branches flipped.
-- case_i5c :: Assertion
-- case_i5c = assertException ["Multiple puts to an IVar!"] i5c

-- i5c = runParIO $
--      do p <- newPair
--         putSnd p "hi"

--         -- The forked thread's value is not returned, so we go to a little extra work
--         -- here to bounce the value through the First of the pair.
--         fork $ putFst p =<< getSnd p
--         waste_time
        
--         putSnd p "there"
--         getFst p

-- -- | Another multiple put error.  This one makes sure that ANY tops get thrown as
-- -- exceptions, or we have full nondeterminism (not even limited guarantees), the
-- -- program would return "a" or "b".
-- case_i6a :: Assertion
-- case_i6a = assertException ["Multiple puts to an IVar!"] i6a
-- i6a = runParIO (
--      do p <- newPair
--         putFst p 3

--         -- TODO: Randomize these amounts of time:
--         fork $ do waste_time
--                   putSnd p "a"
--         fork $ do waste_time
--                   putSnd p "b"
--         -- There's no 'consume' here; so we should really just get a
--         -- "Multiple puts to an IVar!" exception.
--         getSnd p)


-- -- TODO:
-- --------------------------------
-- -- | This test, semantically, has two possible outcomes.  It can return "hi" or an
-- -- error.  That's quasi-determinism.  In practice, we force it to have one outcome by
-- -- wasting a significant amount of time in one branch.
-- --------------------------------


-- waste_time = loop 1000 3.3
--  where
--    loop 0 acc  = if acc < 10 then return acc else return 0
--    loop i !acc = loop (i - 1) (sin acc + 1.0)

-- -- More pairs
-- case_v6 :: Assertion
-- case_v6 = assertEqual "fancy pairs"
--           33 =<< runParIO (
--      do p1 <- newPair
--         p2 <- newPair
--         fork $ do x <- getFst p1
--                   putSnd p2 x 
--         fork $ do x <- getSnd p2
--                   putSnd p1 x
--         putFst p1 33
--         getSnd p1)


--------------------------------------------------------------------------------
-- Freeze-related tests:
--------------------------------------------------------------------------------

case_dftest0 = assertEqual "manual freeze, outer layer" "hello" =<< dftest0

dftest0 :: IO String
dftest0 = runParIO $ do
  iv1 <- IV.new
  iv2 <- IV.new
  IV.put_ iv1 iv2
  IV.put_ iv2 "hello"
  m <- IV.freezeIVar iv1
  case m of
    Just i -> IV.get i

case_dftest1 = assertEqual "deefreeze double ivar" (Just "hello") =<< dftest1

-- | Should return (Just (Just "hello"))
dftest1 :: IO (Maybe String)
dftest1 = runParIO $ do
  iv1 <- IV.new
  iv2 <- IV.new
  IV.put_ iv1 iv2
  IV.put_ iv2 "hello"
  Just x <- IV.freezeIVar iv1
  IV.freezeIVar x

case_dftest3 = assertEqual "freeze simple ivar" (Just 3) =<< dftest3
dftest3 :: IO (Maybe Int)
dftest3 = runParIO $ do
  iv1 <- IV.new
  IV.put_ iv1 (3::Int)
  IV.freezeIVar iv1 


--FIXME:

-- -- | Polymorphic version of previous.  DeepFrz is more flexible than regular
-- -- freeze, because we can pick multiple return types for the same code.  But we must
-- -- be very careful with this kind of thing due to the 's' type variables.
-- dftest4_ :: DeepFrz (IV.IVar s1 Int) =>
--             Par QuasiDet s1 b
-- dftest4_ = do
--   iv1 <- newBottom 
--   IV.put_ iv1 (3::Int)
--   res <- IV.freezeIVar iv1 
--   return res

-- case_dftest4a = assertEqual "freeze polymorphic 1" (Just 3) =<< dftest4a
-- dftest4a :: IO (Maybe Int)
-- dftest4a = runParIO dftest4_

------------------------------------------------------------------------------------------
-- Show instances
------------------------------------------------------------------------------------------

case_show01 :: Assertion
case_show01 = assertEqual "show for IVar" "Just 3" show01
show01 :: String
show01 = show$ runParThenFreeze $ do v <- IV.new; IV.put v (3::Int); return v

-- | It happens that these come out in the opposite order from the Pure one:
case_show02 :: Assertion
case_show02 = assertEqual "show for SLMap" "{IMap: (\"key2\",44), (\"key1\",33)}" show02
show02 :: String
show02 = show$ runParThenFreeze $ do
  mp <- SM.newEmptyMap
  SM.insert "key1" (33::Int) mp
  SM.insert "key2" (44::Int) mp  
  return mp

case_show03 :: Assertion
case_show03 = assertEqual "show for PureMap" "{IMap: (\"key1\",33), (\"key2\",44)}" show03
show03 :: String
show03 = show$ runParThenFreeze $ do
  mp <- IM.newEmptyMap
  IM.insert "key1" (33::Int) mp
  IM.insert "key2" (44::Int) mp  
  return mp

case_show04 :: Assertion
case_show04 = assertEqual "show for IStructure" "{IStructure: Just 33, Just 44}" show04
show04 :: String
show04 = show$ runParThenFreeze $ do
  ist <- ISt.newIStructure 2
  ISt.put ist 0 (33::Int)
  ISt.put ist 1 (44::Int)
  return ist

case_show05 :: Assertion
case_show05 = assertEqual "show for PureSet" "{ISet: 33, 44}" (show show05)
show05 :: ISet Frzn Int
show05 = runParThenFreeze $ do
  is <- IS.newEmptySet
  IS.insert (33::Int) is
  IS.insert (44::Int) is
  return is

-- | It happens that these come out in the opposite order from the Pure one:
case_show06 :: Assertion
case_show06 = assertEqual "show for SLSet" "{ISet: 44, 33}" (show show06)
show06 :: SS.ISet Frzn Int
show06 = runParThenFreeze $ do
  is <- SS.newEmptySet
  SS.insert (33::Int) is
  SS.insert (44::Int) is
  return is

----------------------------------------
-- Test sortFrzn instances:

case_show05B :: Assertion
case_show05B = assertEqual "show for PureSet/Trvrsbl" "AFoldable [33, 44]" (show show05B)
show05B :: G.AFoldable Int
show05B = G.sortFrzn show05

case_show06B :: Assertion
case_show06B = assertEqual "show for SLSet/Trvrsbl" "AFoldable [44, 33]" (show show06B)
show06B :: G.AFoldable Int
show06B = G.sortFrzn show06

------------------------------------------------------------------------------------------
-- Memo tables
------------------------------------------------------------------------------------------

case_mem01 :: Assertion
case_mem01 = assertEqual "memo table test 1" (11,101) mem01
mem01 :: (Integer, Integer)
mem01 = runPar $ do
  m <- makeMemo (return . (+1))
  a <- getMemo m 10
  b <- getMemo m 100
  return (a,b)

