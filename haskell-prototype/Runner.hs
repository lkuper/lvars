{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns, OverloadedStrings #-}

-- Compile-time options:
--   PURE        -- use LVarTracePure
--
-- Run-time options:
--   W = work to do per vertex
--   K = max hops of the connected component to explore
--   (OR N = target vertices to visit (will overshoot))

#ifdef PURE
#warning "Using the PURE version"
import LVarTracePure
#else
import LVarTraceIO
#endif

import           Control.DeepSeq (deepseq)
import           Control.Exception (evaluate)
import           Control.Monad (forM_, when)
import           Control.Monad.Par.Combinator (parMap, parMapM, parFor, InclusiveRange(..))
import           Control.Monad.Par.Class (ParFuture)
import           Control.DeepSeq         (NFData)
import           Data.Int
import           Data.Word
import           Data.IORef
import           Data.List as L
import           Data.List.Split (chunksOf)
import qualified Data.Set as Set
import qualified Data.IntSet as IS
import qualified Data.ByteString.Lazy.Char8 as B
import           Data.Traversable (Traversable)
import           Data.Map as Map (toList, fromListWith)
import           Data.Time.Clock (getCurrentTime, diffUTCTime)
import           GHC.Conc (numCapabilities)
import           Text.Printf (printf)
import           System.Mem (performGC)
import           System.IO.Unsafe (unsafePerformIO)
import           System.Environment (getEnvironment,getArgs)
import           System.CPUTime.Rdtsc (rdtsc)
-- import           Data.Time.Clock (getCurrentTime)
import           System.CPUTime  (getCPUTime)
import qualified Control.Parallel.Strategies as Strat

-- For parsing the file produced by pbbs
import Data.List.Split (splitOn)
import System.IO (openFile, hGetContents, IOMode(ReadMode))

-- For printing inside Par
import Debug.Trace (trace)

-- For representing graphs
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV

--------------------------------------------------------------------------------

-- Vector representation of graphs: the list (or set) at index k is
-- node k's neighbors.
type Graph = V.Vector [Node]
type Graph2 = V.Vector IS.IntSet

type Node = Int

-- Optimized version:
mkGraphFromFile :: String -> IO Graph
mkGraphFromFile file = do
  putStrLn $ "* Begin loading graph from " ++ file ++ "..." 
  t0    <- getCurrentTime
  inStr <- B.readFile file
  let -- Returns a list of edges:
      loop1 [] = []
      loop1 (b1:b2:rst) = do
        case (B.readInt b1, B.readInt b2) of
          (Just (src, _), Just (dst, _)) -> (src, dst) : loop1 rst
          _ -> error $ "Failed parse of bytestrings: " ++ show (B.unwords[b1, b2])
      loop1 _ = error "Odd number of integers in graph file!"

  let edges = case B.words inStr of
               ("EdgeArray":rst) -> loop1 rst
      mx = foldl' (\mx (s,d) -> mx `max` s `max` d) 0 edges
  mg <- MV.replicate (mx+1) []
  forM_ edges $ \ (src,dst) -> do
    -- Interpret this as a DIRECTED graph:    
    ls <- MV.read mg src
    MV.write mg src (dst:ls)
  g <- V.freeze mg
  -- Just to make SURE it's computed:
  putStrLn $ " * Graph loaded: " 
    ++ show(V.length g) ++ " vertices.  Neighbors of vertex 0: "
    ++ show (nbrs g 0)
  t1 <- getCurrentTime
  putStrLn $ " * Time reading/parsing data: " ++ show(diffUTCTime t1 t0)
  return g

-- Neighbors of a node with a given label
nbrs :: Graph -> Int -> [Int]
nbrs g lbl = g V.! lbl

-- For debugging
printGraph :: Graph -> IO ()
printGraph g = do
  let ls = V.toList g
  putStrLn (show ls)
  return ()
    
-- Iterates the sin function n times on its input and returns the sum
-- of all iterations.
sin_iter :: Word64 -> Float -> Float
sin_iter 0  x = x
sin_iter n !x = sin_iter (n - 1) (x + sin x)

type WorkRet = (Float, Node)
type WorkFn = (Node -> WorkRet)

prnt :: String -> Par ()
prnt str = trace str $ return ()

theEnv :: [(String,String)]
theEnv = unsafePerformIO getEnvironment

checkEnv :: Read a => String -> a -> a 
checkEnv v def =
  case lookup v theEnv of
    Just "" -> def
    Just s  -> read s    
    Nothing -> def

verbose :: Bool
verbose = checkEnv "VERBOSE" False

dbg :: Bool
-- dbg = checkEnv "DEBUG" False
dbg = False -- Let it inline, DCE.

main :: IO ()
main = do
  -- Fetch runtime parameters:
  -- First, defaults:
  let graphFile_ :: String
      graphFile_ = "/tmp/grid_125000"
  
  let k_ :: Int
      k_ = 25    -- Number of hops to explore
      
  let w_ :: Word64
      w_ = 20000 -- Amount of work (iterations of sin)

  args <- getArgs
  
-- LK: this way of writing the type annotations is the only way I
  -- can get emacs to not think this is a parse error! :(
  let (graphFile,k,w) = 
        case args of
          []                   -> (graphFile_, k_, w_)
          [graphFiles]         -> (graphFiles, k_, w_)
          [graphFiles, ks]     -> (graphFiles, read ks, w_)
          [graphFiles, ks, ws] -> (graphFiles, read ks, read ws :: Word64)
  
  g <- mkGraphFromFile graphFile

  let startNode = 0
      g2 = V.map IS.fromList g
  evaluate (g2 V.! 0)
  
  let graphThunk :: WorkFn -> IO ()
      graphThunk fn = do
        start_traverse k g2 0 fn
        putStrLn "All done."
  
  let sin_iter_count :: WorkFn
      sin_iter_count x = let f = fromIntegral x in
                         (sin_iter w f, x)

  freq <- measureFreq
  let clocks_per_micro = freq `quot` (1000 * 1000)      
      busy_waiter :: WorkFn
      busy_waiter n = unsafePerformIO $
        wait_microsecs (w * clocks_per_micro) n
  printf "CPU Frequency: %s, clocks per microsecond %s\n"
           (commaint freq) (commaint clocks_per_micro)
  printf "* Beginning benchmark with k=%d and w=%d\n" k w
  
  performGC
  t0 <- getCurrentTime
  startT <- rdtsc  
--  graphThunk sin_iter_count
  graphThunk busy_waiter  
  t1 <- getCurrentTime
  putStrLn $ "SELFTIMED " ++ show (diffUTCTime t1 t0) ++ "\n"

  first <- readIORef first_hit
  let first' = first - startT
  putStrLn$"Start time in cycles: "++commaint startT      
  putStrLn $ "First hit in raw clock cycles was " ++ commaint first'
  let nanos = ((1000 * 1000 * 1000 * (fromIntegral first')) `quot` (fromIntegral freq :: Integer))
  putStrLn $ " In nanoseconds: "++commaint nanos
  putStrLn $ "FIRSTHIT " ++ show nanos

------------------------------------------------------------------------------------------

first_hit :: IORef Word64
first_hit = unsafePerformIO$ newIORef maxBound

-- Wait for a certain number of milleseconds.
wait_microsecs :: Word64 -> Node -> IO WorkRet
wait_microsecs clocks n = do
  myT <- rdtsc
  atomicModifyIORef first_hit (\ t -> (min t myT,()))
  let loop !n = do
        now <- rdtsc
        if now - myT >= clocks
        then return n   
        else loop (n+1)
  cnt <- loop 0
  return (fromIntegral cnt, n)

-- Measure clock frequency, spinning rather than sleeping to try to
-- stay on the same core.
measureFreq :: IO Word64
measureFreq = do
  let millisecond = 1000 * 1000 * 1000 -- picoseconds are annoying
      -- Measure for how long to be sure?      
      measure = 200 * millisecond
--      measure = 1000 * millisecond      
      scale :: Integer
      scale = 1000 * millisecond `quot` measure
  t1 <- rdtsc 
  start <- getCPUTime
  let loop :: Word64 -> Word64 -> IO (Word64,Word64)
      loop !n !last = 
       do t2 <- rdtsc 
	  when (t2 < last) $
	       putStrLn$ "COUNTERS WRAPPED "++ show (last,t2) 
	  cput <- getCPUTime		
	  if (cput - start < measure)
	   then loop (n+1) t2
	   else return (n,t2)
  (n,t2) <- loop 0 t1
  putStrLn$ "  Approx getCPUTime calls per second: "++ commaint (scale * fromIntegral n)
  when (t2 < t1) $ 
    putStrLn$ "WARNING: rdtsc not monotonically increasing, first "++show t1++" then "++show t2++" on the same OS thread"

  return$ fromIntegral (fromIntegral scale * (t2 - t1))

-- Readable large integer printing:
commaint :: (Show a, Integral a) => a -> String
commaint n = 
   reverse $ concat $
   intersperse "," $ 
   chunksOf 3 $ 
   reverse (show n)
