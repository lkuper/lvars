{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# OPTIONS_GHC -fwarn-incomplete-patterns #-}

-- module Apps.CFA.KCFA_LVish
module Main where

-- Translated from Matt Might's article: http://matt.might.net/articles/implementation-of-kcfa-and-0cfa/k-CFA.scm
-- Extended with less ad-hoc support for halting

import Control.Applicative (liftA2, liftA3)
import qualified Control.Monad.State as State
import Control.Monad
import Control.Exception (evaluate)

import qualified Data.Map as M
import qualified Data.Set as S
import Data.List ((\\))
import Debug.Trace

import Control.LVish
import Control.LVish.Internal (liftIO)
import  Data.LVar.Set as IS
import  Data.LVar.Map as IM
import Text.PrettyPrint as PP
import Text.PrettyPrint.GenericPretty (Out(doc,docPrec), Generic)

--------------------------------------------------------------------------------

type Var = String
type Label = Int
data Exp = Halt | Ref Var | Lam Label [Var] Call deriving (Eq, Ord, Show, Generic)
data Call = Call Label Exp [Exp]                 deriving (Eq, Ord, Show, Generic)

-- Abstract state space
data State s = State Call BEnv (Store s) Time
  deriving (Show, Eq, Generic)

-- A binding environment maps variables to addresses
-- (In Matt's example, this mapped to Addr, but I found this a bit redundant
-- since the Var in the Addr can be inferred, so I map straight to Time)
type BEnv = M.Map Var Time

-- A store maps addresses to denotable values
type Store s = IM.IMap Addr s (Denotable s)

-- | An abstact denotable value is a set of possible values
type Denotable s = IS.ISet s Value

-- For pure CPS, closures are the only kind of value
type Value = Clo

-- Closures pair a lambda-term with a binding environment that determines
-- the values of its free variables
data Clo = Closure (Label, [Var], Call) BEnv | HaltClosure | Arbitrary
         deriving (Eq, Ord, Show, Generic)
-- Addresses can point to values in the store. In pure CPS, the only kind of addresses are bindings
type Addr = Bind

-- A binding is minted each time a variable gets bound to a value
data Bind = Binding Var Time
          deriving (Eq, Ord, Show, Generic)
-- In k-CFA, time is a bounded memory of program history.
-- In particular, it is the last k call sites through which
-- the program has traversed.
type Time = [Label]

instance Show (Store s) where
  show _ = "<Store>"

-- State Call BEnv Store Time
instance Ord (State s) where
  compare (State c1 be1 s1 t1)
          (State c2 be2 s2 t2)
    = compare c1 c2    `andthen`
      compare be1 be2  `andthen`
      compare t1 t2    `andthen`
      if s1 == s2
      then EQ
      else error "Ord State: states are equivalent except for Store... FINISHME"

andthen :: Ordering -> Ordering -> Ordering 
andthen EQ b = b
andthen a _  = a

instance Out Call
instance Out Exp
instance Out Clo
instance Out Bind

instance Out (M.Map Var Time) where
  doc = docPrec 0
  docPrec _ mp = doc (M.toList mp)

instance Out (State s) where
  doc = docPrec 0
  docPrec _ (State call benv _str time) = 
   PP.text "State" <+> doc call 
                   <+> doc benv 
                   <+> doc time

--------------------------------------------------------------------------------

-- | Mutate a store to increase the set of values that an Addr may bind to.
storeInsert :: Addr -> Value -> Store s -> Par d s ()
storeInsert a v s = IM.modify s a (IS.putInSet v)
  
-- storeJoin :: Store -> Store -> Store
-- storeJoin = M.unionWith S.union

-- k-CFA parameters

k :: Int
k = 1

tick :: Label -> Time -> Time
tick l t = take k (l:t)

-- k-CFA abstract interpreter

atomEval :: BEnv -> Store s -> Exp -> Par d s (Denotable s)
atomEval benv store Halt    = single HaltClosure
atomEval benv store (Ref x) = case M.lookup x benv of
    Nothing -> error $ "Variable unbound in BEnv: " ++ show x
    Just t  -> IM.getKey (Binding x t) store 
--      case m of
--        Nothing -> error $ "Address unbound in Store: " -- ++ show (Binding x t)
--        Just d  -> return d
        
atomEval benv _  (Lam l v c) = single (Closure (l, v, c) benv)

single :: Ord a => a -> Par d s (ISet s a)
single x = do 
  s <- newEmptySet  
  IS.putInSet x s
  return s

-- | Extend the search from the current state to adjacent states.  This function
--   mutates the set of states (first parameter), adding the new states.
next :: IS.ISet s (State s) -> State s -> Par d s () -- Next states
next seen st0@(State (Call l fun args) benv store time)
  =  -- trace ("next " ++ show (doc st0)) $
  do
    liftIO $ putStrLn ("next " ++ show (doc st0))
    procs   <- atomEval benv store fun
    paramss <- mapM (atomEval benv store) args

    -- Construct a graph of the state space as an adjacency map:
    graph <- newEmptyMap
    let time' = tick l time

    -- This applies to all elements evr added to the set object:
    IS.forEach procs $ \ clo -> do
      case clo of
        HaltClosure -> return ()
        
        Closure (_, formals, call') benv' -> do 
          let benv'' = foldr (\formal benv' -> M.insert formal time benv') benv' formals
          allParamConfs <- IS.cartesianProds paramss
          IS.forEach allParamConfs $ \ params -> do

            -- Hmm... we need to create a new store for the extended bindings
#if 1
            store' <- IM.copy store -- Simply REMOVE this to implicitly STOREJOIN
#else
            let store' = store
#endif                      
            forM_ (formals `zip` params) $ \(formal, params) ->
              storeInsert (Binding formal time) params store'
            let newST = State call' benv'' store' time'
            -- IM.modify graph st0 (putInSet newST)
            putInSet newST seen -- Extending the seen set should spawn more work.
            return ()
          return ()

        Arbitrary -> do 
          allParamConfs <- IS.cartesianProds paramss
          IS.forEach allParamConfs $ \ params -> do
            forM_ params $ \ param -> do
              ms <- escape param store
              case ms of 
                Just state' -> putInSet state' seen
                Nothing -> return ()
          return ()
      return ()
    return ()

storeJoin = error "Shouldn't need storeJoin"

-- Extension of my own design to allow CFA in the presence of arbitrary values.
-- Similar to "sub-0CFA" where locations are inferred to either have either a single
-- lambda flow to them, no lambdas, or all lambdas 
escape :: Value -> Store s -> Par d s (Maybe (State s))
-- If an arbitrary value from outside escapes we don't care:
escape Arbitrary                          _     = return Nothing 
escape HaltClosure                        _     = return Nothing
escape (Closure (_l, formals, call) benv) store = do 
   (benv', store') <- fvStuff formals store
   return $ Just $ 
     (State call (benv `M.union` benv') store' [])


-- | Create an environment and store with empty/Arbitrary bindings.
--   Second argument is an output parameter.
fvStuff :: [Var] -> Store s -> Par d s (BEnv, Store s)
fvStuff xs store = do
  forM_ xs $ \x -> do
    IM.modify store (Binding x []) $ putInSet Arbitrary
  return (M.fromList [(x, []) | x <- xs], store)

-- State-space exploration

-- | Kick off the state space exploration by setting up a handler.
explore :: State s -> Par d s (IS.ISet s (State s))
explore initial = do
  allSeen <- newEmptySet
--  liftIO$ putStrLn$ "Kicking off with an initial state: "++show (doc initial)
  putInSet initial allSeen   
  -- Feedback: recursively feed back new states into allSeen in parallel:
  IS.forEach allSeen (next allSeen)
  return allSeen

 -- NB: Might's dissertation (Section 5.3.5) explains how we can apply widening here to
 -- improve the worst case runtime from exponential to cubic: for an new state from the
 -- work list, we must extract all seen states which match in every element *except* the
 -- store. Then, join those seen stores together. If the potential store is a subset
 -- of the seen ones then we can just loop. Otherwise, union the new store onto a global
 -- "widening" store, update the global store with this one, and do abstract evalution on the state with the new sotre.

-- User interface

-- summarize :: S.Set State -> Par Store
summarize :: IS.ISet s (State s) -> Par d s (Store s)
summarize states = do
  storeFin <- newEmptyMap
  -- Note: a generic union operation could also handle this:
  void$ IS.forEach states $ \ (State _ _ store_n _) -> 
    void$ IM.forEach store_n $ \ key val -> 
      void$ IS.forEach val $ \ elem  -> 
        IM.modify storeFin key $ putInSet elem
  return storeFin
--    S.fold (\(State _ _ store' _) store -> store `storeJoin` store') M.empty states
  
-- ("Monovariant" because it throws away information we know about what time things arrive at)
-- monovariantStore :: Store -> M.Map Var (S.Set Exp)
-- monovariantStore :: Store s -> Par d s (M.Map Var (S.Set Exp))
monovariantStore :: Store s -> Par d s (IM.IMap Var s (IS.ISet s Exp))
monovariantStore store = do 
  -- M.foldrWithKey (\(Binding x _) d res ->
  --                  M.alter (\mb_exp -> Just $ maybe id S.union mb_exp (S.map monovariantValue d)) x res)
  --       M.empty store
  mp <- newEmptyMap
  IM.forEach store $ \ (Binding vr _) d -> do
    -- d' <- IS.traverseSet (return . monovariantValue) d
    IS.forEach d $ \ elm -> do
      let elm' = monovariantValue elm
      IM.modify mp vr (IS.putInSet elm')
    return ()
  return mp
  
 where   
   monovariantValue :: Value -> Exp
   monovariantValue (Closure (l, v, c) _) = Lam l v c
   monovariantValue HaltClosure           = Halt
   monovariantValue Arbitrary             = Ref "unknown"

-- | Perform a complete, monovariant analysis.
-- analyse :: Call -> M.Map Var (S.Set Exp)
-- analyse :: Call -> Snapshot (IM.IMap Var) (Snapshot IS.ISet Exp)
analyse :: Call -> M.Map Var (Snapshot IS.ISet Exp)
analyse e = res 
 where
   IMapSnap res = runParThenFreeze par
   par = do
     newStore <- newEmptyMap 
     (benv, store) <- fvStuff (S.toList (fvsCall e)) newStore
     let initState = State e benv store []
     allStates <- explore initState
     finStore <- summarize allStates
     monovariantStore finStore

    
-- | Get the free vars of an expression 
fvsExp :: Exp -> S.Set Var
fvsExp Halt         = S.empty
fvsExp (Ref x)      = S.singleton x
fvsExp (Lam _ xs c) = fvsCall c S.\\ S.fromList xs

fvsCall :: Call -> S.Set Var
fvsCall (Call _ fun args) = fvsExp fun `S.union` S.unions (map fvsExp args)


-- Helper functions for constructing syntax trees

type UniqM = State.State Int

newLabel :: UniqM Int
newLabel = State.state (\i -> (i, i + 1))

runUniqM :: UniqM a -> a
runUniqM = fst . flip State.runState 0

ref :: Var -> UniqM Exp
ref = return . Ref

lam :: [Var] -> UniqM Call -> UniqM Exp
lam xs c = liftA2 (flip Lam xs) newLabel c

call :: UniqM Exp -> [UniqM Exp] -> UniqM Call
call e es = liftA3 Call newLabel e (sequence es)

let_ :: Var -> UniqM Exp -> UniqM Call -> UniqM Call
let_ x e c = call (lam [x] c) [e]

halt :: UniqM Exp -> UniqM Call
halt e = call (return Halt) [e]

-- The Standard Example
--
-- In direct style:
--
-- let id = \x -> x
--     a = id (\z -> halt z)
--     b = id (\y -> halt y)
-- in halt b
standardExample :: UniqM Call
standardExample = 
  let_ "id" (lam ["x", "k"] (call (ref "k") [ref "x"])) $
  call (ref "id") [lam ["z"] (halt (ref "z")),
                   lam ["a"] (call (ref "id") [lam ["y"] (halt (ref "y")),
                                               lam ["b"] (halt (ref "b"))])]

-- Example with free varibles (showing escapes):
fvExample :: UniqM Call
fvExample = 
  let_ "id" (lam ["x", "k"] (call (ref "k") [ref "x"])) $
  call (ref "id") [lam ["z"] (call (ref "escape") [ref "z"]),
                   lam ["a"] (call (ref "id") [lam ["y"] (call (ref "escape") [ref "y"]),
                                               lam ["b"] (call (ref "escape") [ref "b"])])]

-- main = forM_ [fvExample, standardExample] runExample
main = runExample standardExample

runExample example = do
  let res = M.toList (analyse (runUniqM example))
  len <- evaluate (length res)
  putStrLn$ "===== #results = "++show len
  forM_ res $ \(x, ISetSnap es) -> do
    putStrLn (x ++ ":")
    mapM_ (putStrLn . ("  " ++) . show) (S.toList es)

         -- forM_ (M.toList (analyse (runUniqM example))) $ \(x, es) -> do
         --   putStrLn (x ++ ":")
         --   mapM_ (putStrLn . ("  " ++) . show) (S.toList es)
