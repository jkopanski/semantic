{-# LANGUAGE ConstraintKinds, DefaultSignatures, GADTs, ScopedTypeVariables, TypeOperators, UndecidableInstances #-}
module Data.Abstract.Evaluatable
( module X
, MonadEvaluatable
, Evaluatable(..)
, Unspecialized(..)
, EvalError(..)
, LoadError(..)
, ResolutionError(..)
, variable
, evaluateInScopedEnv
, evaluatePackage
, evaluatePackageBody
, throwEvalError
, resolve
, traceResolve
, listModulesInDir
, require
, load
) where

import           Control.Abstract.Addressable as X
import           Control.Abstract.Analysis as X hiding (LoopControl(..), Return(..))
import           Control.Abstract.Analysis (LoopControl, Return(..))
import           Control.Monad.Effect as Eff
import           Data.Abstract.Address
import           Data.Abstract.Declarations as X
import           Data.Abstract.Environment as X
import qualified Data.Abstract.Exports as Exports
import           Data.Abstract.FreeVariables as X
import           Data.Abstract.Module
import           Data.Abstract.ModuleTable as ModuleTable
import           Data.Abstract.Origin (packageOrigin)
import           Data.Abstract.Package as Package
import           Data.Language
import           Data.Scientific (Scientific)
import           Data.Semigroup.App
import           Data.Semigroup.Foldable
import           Data.Semigroup.Reducer hiding (unit)
import           Data.Term
import           Prologue

type MonadEvaluatable location term value effects m =
  ( Declarations term
  , Evaluatable (Base term)
  , FreeVariables term
  , Member (EvalClosure term value) effects
  , Member Fail effects
  , Member (LoopControl value) effects
  , Member (Resumable (Unspecialized value)) effects
  , Member (Resumable (LoadError term)) effects
  , Member (Resumable (EvalError value)) effects
  , Member (Resumable (ResolutionError value)) effects
  , Member (Resumable (AddressError location value)) effects
  , Member (Return value) effects
  , MonadAddressable location effects m
  , MonadEvaluator location term value effects m
  , MonadValue location value effects m
  , Recursive term
  , Reducer value (Cell location value)
  )

-- | An error thrown when we can't resolve a module from a qualified name.
data ResolutionError value resume where
  NotFoundError :: String   -- ^ The path that was not found.
                -> [String] -- ^ List of paths searched that shows where semantic looked for this module.
                -> Language -- ^ Language.
                -> ResolutionError value ModulePath

  GoImportError :: FilePath -> ResolutionError value [ModulePath]

deriving instance Eq (ResolutionError a b)
deriving instance Show (ResolutionError a b)
instance Show1 (ResolutionError value) where liftShowsPrec _ _ = showsPrec
instance Eq1 (ResolutionError value) where
  liftEq _ (NotFoundError a _ l1) (NotFoundError b _ l2) = a == b && l1 == l2
  liftEq _ (GoImportError a) (GoImportError b) = a == b
  liftEq _ _ _ = False

-- | An error thrown when loading a module from the list of provided modules. Indicates we weren't able to find a module with the given name.
data LoadError term resume where
  LoadError :: ModulePath -> LoadError term [Module term]

deriving instance Eq (LoadError term resume)
deriving instance Show (LoadError term resume)
instance Show1 (LoadError term) where
  liftShowsPrec _ _ = showsPrec
instance Eq1 (LoadError term) where
  liftEq _ (LoadError a) (LoadError b) = a == b

-- | The type of error thrown when failing to evaluate a term.
data EvalError value resume where
  -- Indicates we weren't able to dereference a name from the evaluated environment.
  FreeVariableError :: Name -> EvalError value value
  FreeVariablesError :: [Name] -> EvalError value Name
  -- Indicates that our evaluator wasn't able to make sense of these literals.
  IntegerFormatError  :: ByteString -> EvalError value Integer
  FloatFormatError    :: ByteString -> EvalError value Scientific
  RationalFormatError :: ByteString -> EvalError value Rational
  DefaultExportError  :: EvalError value ()
  ExportError         :: ModulePath -> Name -> EvalError value ()
  EnvironmentLookupError :: value -> EvalError value value

-- | Evaluate a term within the context of the scoped environment of 'scopedEnvTerm'.
--   Throws an 'EnvironmentLookupError' if @scopedEnvTerm@ does not have an environment.
evaluateInScopedEnv :: MonadEvaluatable location term value effects m
                    => m effects value
                    -> m effects value
                    -> m effects value
evaluateInScopedEnv scopedEnvTerm term = do
  value <- scopedEnvTerm
  scopedEnv <- scopedEnvironment value
  maybe (throwEvalError (EnvironmentLookupError value)) (flip localEnv term . mergeEnvs) scopedEnv

-- | Look up and dereference the given 'Name', throwing an exception for free variables.
variable :: ( Member (Resumable (AddressError location value)) effects
            , Member (Resumable (EvalError value)) effects
            , MonadAddressable location effects m
            , MonadEvaluator location term value effects m
            )
         => Name
         -> m effects value
variable name = lookupWith deref name >>= maybeM (throwResumable (FreeVariableError name))

deriving instance Eq a => Eq (EvalError a b)
deriving instance Show a => Show (EvalError a b)
instance Show value => Show1 (EvalError value) where
  liftShowsPrec _ _ = showsPrec
instance Eq term => Eq1 (EvalError term) where
  liftEq _ (FreeVariableError a) (FreeVariableError b)     = a == b
  liftEq _ (FreeVariablesError a) (FreeVariablesError b)   = a == b
  liftEq _ DefaultExportError DefaultExportError           = True
  liftEq _ (ExportError a b) (ExportError c d)             = (a == c) && (b == d)
  liftEq _ (IntegerFormatError a) (IntegerFormatError b)   = a == b
  liftEq _ (FloatFormatError a) (FloatFormatError b)       = a == b
  liftEq _ (RationalFormatError a) (RationalFormatError b) = a == b
  liftEq _ (EnvironmentLookupError a) (EnvironmentLookupError b) = a == b
  liftEq _ _ _                                             = False


throwEvalError :: (Member (Resumable (EvalError value)) effects, MonadEvaluator location term value effects m) => EvalError value resume -> m effects resume
throwEvalError = throwResumable


data Unspecialized a b where
  Unspecialized :: { getUnspecialized :: Prelude.String } -> Unspecialized value value

instance Eq1 (Unspecialized a) where
  liftEq _ (Unspecialized a) (Unspecialized b) = a == b

deriving instance Eq (Unspecialized a b)
deriving instance Show (Unspecialized a b)
instance Show1 (Unspecialized a) where
  liftShowsPrec _ _ = showsPrec

-- | The 'Evaluatable' class defines the necessary interface for a term to be evaluated. While a default definition of 'eval' is given, instances with computational content must implement 'eval' to perform their small-step operational semantics.
class Evaluatable constr where
  eval :: ( Member (EvalModule term value) effects
          , MonadEvaluatable location term value effects m
          )
       => SubtermAlgebra constr term (m effects value)
  default eval :: (MonadEvaluatable location term value effects m, Show1 constr) => SubtermAlgebra constr term (m effects value)
  eval expr = throwResumable (Unspecialized ("Eval unspecialized for " ++ liftShowsPrec (const (const id)) (const id) 0 expr ""))


-- Instances

-- | If we can evaluate any syntax which can occur in a 'Union', we can evaluate the 'Union'.
instance Apply Evaluatable fs => Evaluatable (Union fs) where
  eval = Prologue.apply (Proxy :: Proxy Evaluatable) eval

-- | Evaluating a 'TermF' ignores its annotation, evaluating the underlying syntax.
instance Evaluatable s => Evaluatable (TermF s a) where
  eval = eval . termFOut

--- | '[]' is treated as an imperative sequence of statements/declarations s.t.:
---
---   1. Each statement’s effects on the store are accumulated;
---   2. Each statement can affect the environment of later statements (e.g. by 'modify'-ing the environment); and
---   3. Only the last statement’s return value is returned.
instance Evaluatable [] where
  -- 'nonEmpty' and 'foldMap1' enable us to return the last statement’s result instead of 'unit' for non-empty lists.
  eval = maybe unit (runApp . foldMap1 (App . subtermValue)) . nonEmpty

-- Resolve a list of module paths to a possible module table entry.
resolve :: MonadEvaluatable location term value effects m
        => [FilePath]
        -> m effects (Maybe ModulePath)
resolve names = do
  tbl <- askModuleTable
  pure $ find (`ModuleTable.member` tbl) names

traceResolve :: (Show a, Show b) => a -> b -> c -> c
traceResolve name path = trace ("resolved " <> show name <> " -> " <> show path)

listModulesInDir :: MonadEvaluatable location term value effects m
        => FilePath
        -> m effects [ModulePath]
listModulesInDir dir = ModuleTable.modulePathsInDir dir <$> askModuleTable

-- | Require/import another module by name and return it's environment and value.
--
-- Looks up the term's name in the cache of evaluated modules first, returns if found, otherwise loads/evaluates the module.
require :: ( Member (EvalModule term value) effects
           , Member (Resumable (LoadError term)) effects
           , MonadEvaluator location term value effects m
           , MonadValue location value effects m
           )
        => ModulePath
        -> m effects (Environment location value, value)
require = requireWith evaluateModule

requireWith :: ( Member (Resumable (LoadError term)) effects
               , MonadEvaluator location term value effects m
               , MonadValue location value effects m
               )
            => (Module term -> m effects value)
            -> ModulePath
            -> m effects (Environment location value, value)
requireWith with name = getModuleTable >>= maybeM (loadWith with name) . ModuleTable.lookup name

-- | Load another module by name and return it's environment and value.
--
-- Always loads/evaluates.
load :: ( Member (EvalModule term value) effects
        , Member (Resumable (LoadError term)) effects
        , MonadEvaluator location term value effects m
        , MonadValue location value effects m
        )
     => ModulePath
     -> m effects (Environment location value, value)
load = loadWith evaluateModule

loadWith :: ( Member (Resumable (LoadError term)) effects
            , MonadEvaluator location term value effects m
            , MonadValue location value effects m
            )
         => (Module term -> m effects value)
         -> ModulePath
         -> m effects (Environment location value, value)
loadWith with name = askModuleTable >>= maybeM notFound . ModuleTable.lookup name >>= evalAndCache
  where
    notFound = throwResumable (LoadError name)

    evalAndCache []     = (,) emptyEnv <$> unit
    evalAndCache [x]    = evalAndCache' x
    evalAndCache (x:xs) = do
      (env, _) <- evalAndCache' x
      (env', v') <- evalAndCache xs
      pure (mergeEnvs env env', v')

    evalAndCache' x = do
      let mPath = modulePath (moduleInfo x)
      LoadStack{..} <- getLoadStack
      if mPath `elem` unLoadStack
        then do -- Circular load, don't keep evaluating.
          v <- trace ("load (skip evaluating, circular load): " <> show mPath) unit
          pure (emptyEnv, v)
        else do
          modifyLoadStack (loadStackPush mPath)
          v <- trace ("load (evaluating): " <> show mPath) $ with x
          modifyLoadStack loadStackPop
          traceM ("load done:" <> show mPath)
          env <- filterEnv <$> getExports <*> getEnv
          modifyModuleTable (ModuleTable.insert name (env, v))
          pure (env, v)

    -- TODO: If the set of exports is empty because no exports have been
    -- defined, do we export all terms, or no terms? This behavior varies across
    -- languages. We need better semantics rather than doing it ad-hoc.
    filterEnv :: Exports.Exports l a -> Environment l a -> Environment l a
    filterEnv ports env
      | Exports.null ports = env
      | otherwise = Exports.toEnvironment ports `mergeEnvs` overwrite (Exports.aliases ports) env


-- | Evaluate a (root-level) term to a value using the semantics of the current analysis.
evalModule :: forall location term value effects m
           .  ( Member (EvalModule term value) effects
              , MonadAnalysis location term value effects m
              , MonadEvaluatable location term value effects m
              )
           => Module term
           -> m effects value
evalModule m = raiseHandler
  (interpose @(EvalModule term value) pure (\ (EvalModule m) yield -> lower @m (evalModule m) >>= yield))
  (analyzeModule (subtermValue . moduleBody) (fmap (Subterm <*> evalTerm) m))
  where evalTerm term = catchReturn @m @value
          (raiseHandler
            (interpose @(EvalClosure term value) pure (\ (EvalClosure term) yield -> lower (evalTerm term) >>= yield))
            (foldSubterms (analyzeTerm eval) term))
          (\ (Return value) -> pure value)

-- | Evaluate a given package.
evaluatePackage :: ( Member (EvalModule term value) effects
                   , MonadAnalysis location term value effects m
                   , MonadEvaluatable location term value effects m
                   )
                => Package term
                -> m effects [value]
evaluatePackage p = pushOrigin (packageOrigin p) (evaluatePackageBody (packageBody p))

-- | Evaluate a given package body (module table and entry points).
evaluatePackageBody :: ( Member (EvalModule term value) effects
                       , MonadAnalysis location term value effects m
                       , MonadEvaluatable location term value effects m
                       )
                    => PackageBody term
                    -> m effects [value]
evaluatePackageBody body = withPrelude (packagePrelude body) $
  localModuleTable (<> packageModules body) (traverse evaluateEntryPoint (ModuleTable.toPairs (packageEntryPoints body)))
  where
    evaluateEntryPoint (m, sym) = do
      (_, v) <- requireWith evalModule m
      maybe (pure v) ((`call` []) <=< variable) sym
    withPrelude Nothing a = a
    withPrelude (Just prelude) a = do
      preludeEnv <- evalModule prelude *> getEnv
      withDefaultEnvironment preludeEnv a
