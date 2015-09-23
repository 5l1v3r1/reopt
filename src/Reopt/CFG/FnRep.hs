{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}

module Reopt.CFG.FnRep
   ( FnAssignment(..)
   , FnAssignRhs(..)
   , FnValue(..)
   , Function(..)
   , FnBlock(..)
   , FnStmt(..)
   , FnTermStmt(..)
   , FnRegValue(..)
   , FnPhiVar(..)
   , FnReturnVar(..)
   ) where

import           Control.Lens
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Parameterized.Some
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Word
import           Numeric (showHex)
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.X86State

import Reopt.CFG.Representation(App(..), AssignId, BlockLabel, CodeAddr
                               , ppApp, ppLit, ppAssignId, sexpr)
import           Reopt.Machine.Types

commas :: [Doc] -> Doc
commas = hsep . punctuate (char ',')

data FnAssignment tp
   = FnAssignment { fnAssignId :: !AssignId
                  , fnAssignRhs :: !(FnAssignRhs tp)
                  }

instance Pretty (FnAssignment tp) where
  pretty (FnAssignment lhs rhs) = ppAssignId lhs <+> text ":=" <+> pretty rhs

-- FIXME: this is in the same namespace as assignments, maybe it shouldn't be?

newtype FnPhiVar (tp :: Type) = FnPhiVar { unFnPhiVar :: AssignId }

instance Pretty (FnPhiVar tp) where
  pretty = ppAssignId . unFnPhiVar
  
-- | The right-hand side of a function assingment statement.
data FnAssignRhs (tp :: Type) where
  -- An expression with an undefined value.
  FnSetUndefined :: !(NatRepr n) -- Width of undefined value.
                 -> FnAssignRhs (BVType n)
  FnReadMem :: !(FnValue (BVType 64))
            -> !(TypeRepr tp)
            -> FnAssignRhs tp
  FnEvalApp :: !(App FnValue tp)
            -> FnAssignRhs tp
  FnAlloca :: !(FnValue (BVType 64))
           -> FnAssignRhs (BVType 64)

ppFnAssignRhs :: (forall u . FnValue u -> Doc)
                 -> FnAssignRhs tp
                 -> Doc
ppFnAssignRhs _  (FnSetUndefined w) = text "undef ::" <+> brackets (text (show w))
ppFnAssignRhs _  (FnReadMem loc _)  = text "*" <> pretty loc
ppFnAssignRhs pp (FnEvalApp a) = ppApp pp a
ppFnAssignRhs _pp (FnAlloca sz) = sexpr "alloca" [pretty sz]

instance Pretty (FnAssignRhs tp) where
  pretty = ppFnAssignRhs pretty

-- tp <- {BVType 64, BVType 128}
data FnReturnVar tp = FnReturnVar { frAssignId :: !AssignId
                                  , frReturnType :: !(TypeRepr tp) }

instance Pretty (FnReturnVar tp) where
  pretty = ppAssignId . frAssignId

-- | A function value.
data FnValue (tp :: Type) where
  FnValueUnsupported :: FnValue tp
  -- A value that is actually undefined, like a non-argument register at
  -- the start of a function.
  FnUndefined :: FnValue tp
  FnConstantValue :: !(NatRepr n) -> !Integer -> FnValue (BVType n)
  -- Value from an assignment statement.
  FnAssignedValue :: !(FnAssignment tp) -> FnValue tp
  -- Value from a phi node
  FnPhiValue :: !(FnPhiVar tp) -> FnValue tp
  -- A value returned by a function call (rax/xmm0)
  FnReturn :: FnReturnVar tp -> FnValue tp
  -- The entry pointer to a function.
  FnFunctionEntryValue :: !Word64 -> FnValue (BVType 64)
  -- A pointer to an internal block at the given address.
  FnBlockValue :: !Word64 -> FnValue (BVType 64)
  -- Value is an interget argument passed via a register.
  FnIntArg   :: !Int -> FnValue (BVType 64)
  -- Value is a function argument passed via a floating point XMM
  -- register.
  FnFloatArg :: !Int -> FnValue (BVType 128)
  -- A global address
  FnGlobalDataAddr :: !Word64 -> FnValue (BVType 64)

instance Pretty (FnValue tp) where
  pretty FnValueUnsupported       = text "unsupported"
  pretty FnUndefined              = text "undef"
  pretty (FnConstantValue sz n)   = ppLit sz n
  pretty (FnAssignedValue assign) = ppAssignId (fnAssignId assign)
  pretty (FnPhiValue phi)         = ppAssignId (unFnPhiVar phi)
  pretty (FnReturn var)           = pretty var
  pretty (FnFunctionEntryValue n) = text "FunctionEntry"
                                    <> parens (pretty $ showHex n "")
  pretty (FnBlockValue n)         = text "BlockValue"
                                    <> parens (pretty $ showHex n "")
  pretty (FnIntArg n)             = text "arg" <> int n
  pretty (FnFloatArg n)           = text "fparg" <> int n
  pretty (FnGlobalDataAddr addr)  = text "data@"
                                    <> parens (pretty $ showHex addr "")

------------------------------------------------------------------------
-- Function definitions

data Function = Function { fnAddr :: CodeAddr
                         , fnBlocks :: [FnBlock]
                         }

instance Pretty Function where
  pretty fn =
    text "function " <+> pretty (showHex (fnAddr fn) "")
    <$$>
    lbrace
    <$$>
    (nest 4 $ vcat (pretty <$> fnBlocks fn))
    <$$>
    rbrace

data FnRegValue tp where
  -- This is a callee saved register.
  CalleeSaved :: N.RegisterName 'N.GP -> FnRegValue (N.RegisterType 'N.GP)
  -- A value assigned to a register
  FnRegValue :: !(FnValue tp) -> FnRegValue tp
  -- An uninitialized value
  FnRegUninitialized :: FnRegValue tp

instance Pretty (FnRegValue tp) where
  pretty (CalleeSaved r)     = text "calleeSaved" <> parens (text $ show r)
  pretty (FnRegValue v)      = pretty v
  pretty FnRegUninitialized  = text "uninitialized"

data FnBlock
   = FnBlock { fbLabel :: !BlockLabel
               -- We do this to decouple block translation from
               -- cfg/phi construction.
             , fbPhiVars  :: Maybe (X86State FnPhiVar)
               -- Maps predecessor label onto the reg value at that
               -- block
             , fbPhiNodes :: Map BlockLabel (X86State FnValue)
             , fbStmts :: ![FnStmt]
             , fbTerm  :: !(FnTermStmt)
             }

instance PrettyRegValue FnRegValue where
  ppValueEq _ v = Just $ pretty v

instance Pretty FnBlock where
  pretty b =
    pretty (fbLabel b) <$$>
    indent 2 (ppPhis
              <$$> vcat (pretty <$> fbStmts b)
              <$$> pretty (fbTerm b))
    where
      ppPhis = case fbPhiVars b of
        Nothing -> mempty
        Just vs -> vcat (map (go vs) x86StateRegisters)
      go vs (Some r) =
        pretty (vs ^. register r) <+> text ":= phi "
        <+> hsep (punctuate comma $ map (goLbl r) (Map.assocs $ fbPhiNodes b))
      goLbl r (lbl, node) =
                parens (pretty lbl <> comma <+> pretty (node ^. register r))


data FnStmt
  = forall tp . FnWriteMem !(FnValue (BVType 64)) !(FnValue tp)
    -- | A comment
  | FnComment !Text
    -- | An assignment statement
  | forall tp . FnAssignStmt !(FnAssignment tp)


instance Pretty FnStmt where
  pretty s =
    case s of
      FnWriteMem addr val -> text "*" <> parens (pretty addr) <+> text "=" <+> pretty val
      FnComment msg -> text "#" <+> text (Text.unpack msg)
      FnAssignStmt assign -> pretty assign

data FnTermStmt
   = FnJump !BlockLabel
   | FnRet !(FnValue (BVType 64)) !(FnValue (BVType 128))
   | FnBranch !(FnValue BoolType) !BlockLabel !BlockLabel
     -- ^ A branch to a block within the function, along with the return vars.
   | FnCall !(FnValue (BVType 64)) [Some FnValue]
            !(FnReturnVar (BVType 64))
            !(FnReturnVar XMMType)
            BlockLabel
     -- ^ A call statement to the given location with the arguments listed that
     -- returns to the label.
   | FnTermStmtUndefined

instance Pretty FnTermStmt where
  pretty s =
    case s of
      FnBranch c x y -> text "branch" <+> pretty c <+> pretty x <+> pretty y
      FnJump lbl -> text "jump" <+> pretty lbl
      FnRet intr floatr -> text "return" <+> pretty intr <+> pretty floatr
      FnCall f args intr floatr lbl ->
        let arg_docs = viewSome pretty <$> args
         in parens (pretty intr <> comma <+> pretty floatr)
            <+> text ":=" <+> text "call"
            <+> pretty f <> parens (commas arg_docs) <+> pretty lbl
      FnTermStmtUndefined -> text "undefined term"