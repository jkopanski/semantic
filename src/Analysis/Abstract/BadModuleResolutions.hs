{-# LANGUAGE GeneralizedNewtypeDeriving, ScopedTypeVariables, TypeApplications, TypeFamilies, TypeOperators, UndecidableInstances #-}
module Analysis.Abstract.BadModuleResolutions where

import Control.Abstract.Analysis
import Data.Abstract.Evaluatable
import Prologue

newtype BadModuleResolutions m (effects :: [* -> *]) a = BadModuleResolutions (m effects a)
  deriving (Alternative, Applicative, Functor, Effectful, Monad, MonadFail, MonadFresh)

deriving instance MonadControl term effects m                    => MonadControl term effects (BadModuleResolutions m)
deriving instance MonadEnvironment location value effects m      => MonadEnvironment location value effects (BadModuleResolutions m)
deriving instance MonadHeap location value effects m             => MonadHeap location value effects (BadModuleResolutions m)
deriving instance MonadModuleTable location term value effects m => MonadModuleTable location term value effects (BadModuleResolutions m)
deriving instance MonadEvaluator location term value effects m   => MonadEvaluator location term value effects (BadModuleResolutions m)

instance ( Effectful m
         , Member (Resumable (ResolutionError value)) effects
         , Member (State [Name]) effects
         , MonadAnalysis location term value effects m
         , MonadValue location value effects (BadModuleResolutions m)
         )
      => MonadAnalysis location term value effects (BadModuleResolutions m) where
  type Effects location term value (BadModuleResolutions m) = State [Name] ': Effects location term value m

  analyzeTerm eval term = resume @(ResolutionError value) (liftAnalyze analyzeTerm eval term) (
        \yield error -> do
          traceM ("ResolutionError:" <> show error)
          case error of
            (RubyError nameToResolve) -> yield nameToResolve
            (TypeScriptError nameToResolve) -> yield nameToResolve)

  analyzeModule = liftAnalyze analyzeModule
