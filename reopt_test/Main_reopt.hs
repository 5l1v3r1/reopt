{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main (main) where

import Control.Applicative
import           Control.Concurrent
import           Control.Lens
import           Control.Monad
import           Control.Monad.State.Strict
import           Control.Monad.Reader
import           Data.Bits
import qualified Data.ByteString as B
import           Data.Elf
import           Data.Foldable (traverse_)
import           Data.Int
import           Data.List
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Word
import           Data.Version
import           GHC.TypeLits
import           Numeric (showHex)
import           System.Console.CmdArgs.Explicit as CmdArgs
import           System.Environment (getArgs)
import           System.Exit (exitFailure)
import System.IO
import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))
import Debug.Trace

import Data.Parameterized.NatRepr
import Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF

-- import Reopt.Semantics.BitVector
import           Numeric (readHex)

import           Paths_reopt (version)
import           Data.Type.Equality as Equality

import           Flexdis86 (InstructionInstance(..), ppInstruction, ByteReader(..), defaultX64Disassembler, disassembleInstruction)
import           Reopt
import           Reopt.Analysis.AbsState
import           Reopt.CFG.CFGDiscovery
import           Reopt.CFG.Representation
import qualified Reopt.Machine.StateNames as N
import           Reopt.Machine.Types
import           Reopt.Machine.X86State
--import           Reopt.Semantics.ConcreteState
import           Reopt.Object.Memory
import           Reopt.Object.Loader
import           Reopt.Concrete.BitVector
import           Reopt.Concrete.MachineState as MS
import           Reopt.Semantics.DeadRegisterElimination
import           Reopt.Semantics.Monad (Type(..), bvLit)
import System.Posix.Waitpid as W
import System.Posix.Types
import System.Posix.Process
import System.Posix.Signals
import System.Linux.Ptrace
import System.Linux.Ptrace.Syscall
import System.Linux.Ptrace.Types
import System.Linux.Ptrace.X86_64Regs

------------------------------------------------------------------------
-- Args

-- | Action to perform when running
data Action
   = Test            -- * Execute and simulate in parallel, printing errors
   | Instr
   | ShowHelp        -- ^ Print out help message
   | ShowVersion     -- ^ Print out version

-- | Command line arguments.
data Args = Args { _reoptAction :: !Action
                 , _programPath :: !FilePath
                 , _loadStyle   :: !LoadStyle
                 }

-- | How to load Elf file.
data LoadStyle
   = LoadBySection
     -- ^ Load loadable sections in Elf file.
   | LoadBySegment
     -- ^ Load segments in Elf file.

-- | Action to perform when running.
reoptAction :: Simple Lens Args Action
reoptAction = lens _reoptAction (\s v -> s { _reoptAction = v })

-- | Path to load
programPath :: Simple Lens Args FilePath
programPath = lens _programPath (\s v -> s { _programPath = v })

-- | Whether to load file by segment or sections.
loadStyle :: Simple Lens Args LoadStyle
loadStyle = lens _loadStyle (\s v -> s { _loadStyle = v })

-- | Initial arguments if nothing is specified.
defaultArgs :: Args
defaultArgs = Args { _reoptAction = Test
                   , _programPath = ""
                   , _loadStyle = LoadBySection
                   }

------------------------------------------------------------------------
-- Argument processing

arguments :: Mode Args
arguments = mode "reopt_test" defaultArgs help filenameArg flags
  where help = reoptVersion ++ "\n" ++ copyrightNotice
        flags = [ instrFlag
                , testFlag
                , flagHelpSimple (reoptAction .~ ShowHelp)
                , flagVersion (reoptAction .~ ShowVersion)
                ]

testFlag :: CmdArgs.Flag Args
testFlag = flagNone [ "test", "t"] upd help
  where upd = reoptAction .~ Test
        help = "Test concrete semantics by executing in parallel with a binary"

instrFlag :: CmdArgs.Flag Args
instrFlag = flagNone [ "instructions", "i"] upd help
  where upd = reoptAction .~ Instr
        help = "Print disassembly of executed instructions in a binary"

reoptVersion :: String
reoptVersion = "Reopt binary reoptimizer (reopt) "
             ++ versionString ++ ", June 2014."
  where [h,l,r] = versionBranch version
        versionString = show h ++ "." ++ show l ++ "." ++ show r

copyrightNotice :: String
copyrightNotice = "Copyright 2014 Galois, Inc. All rights reserved."

filenameArg :: Arg Args
filenameArg = Arg { argValue = setFilename
                  , argType = "FILE"
                  , argRequire = False
                  }
  where setFilename :: String -> Args -> Either String Args
        setFilename nm a = Right (a & programPath .~ nm)

getCommandLineArgs :: IO Args
getCommandLineArgs = do
  argStrings <- getArgs
  case process arguments argStrings of
    Left msg -> do
      putStrLn msg
      exitFailure
    Right v -> return v

------------------------------------------------------------------------
-- Execution

showUsage :: IO ()
showUsage = do
  putStrLn "For help on using reopt, run \"reopt --help\"."

readElf64 :: FilePath -> IO (Elf Word64)
readElf64 path = do
  when (null path) $ do
    putStrLn "Please specify a binary."
    showUsage
    exitFailure
  bs <- B.readFile path
  case parseElf bs of
    Left (_,msg) -> do
      putStrLn $ "Error reading " ++ path ++ ":"
      putStrLn $ "  " ++ msg
      exitFailure
    Right (Elf32 _) -> do
      putStrLn "32-bit executables are not yet supported."
      exitFailure
    Right (Elf64 e) ->
      return e

readStaticElf :: FilePath -> IO (Elf Word64)
readStaticElf path = do
  e <- readElf64 path
  mi <- elfInterpreter e
  case mi of
    Nothing ->
      return ()
    Just{} ->
      fail "reopt does not yet support generating CFGs from dynamically linked executables."
  return e

mkElfMem :: (ElfWidth w, Functor m, Monad m) => LoadStyle -> Elf w -> m (Memory w)
mkElfMem LoadBySection e = memoryForElfSections e
mkElfMem LoadBySegment e = memoryForElfSegments e

{-test :: Args -> IO ()
test args = do
  e <- readStaticElf (args^.programPath)
  let Identity mem = mkElfMem (args^.loadStyle) e
  child <- traceFile $ args^.programPath
  runStateT (testInner (printRegsAndInstr mem) child) ()
  return ()-}

test :: Args -> IO ()
test args = do
  child <- traceFile $ args^.programPath
  procMem <- openChildProcMem child
  runStateT (testInner (printRegsAndInstrProcMem procMem) child) ()
  return ()

printExecutedInstructions :: Args -> IO ()
printExecutedInstructions args = do
  e <- readStaticElf (args^.programPath)
  let Identity mem = mkElfMem (args^.loadStyle) e
  child <- traceFile $ args^.programPath
  runStateT (testInner (printInstr mem) child) ()
  return ()

traceFile :: FilePath -> IO CPid
traceFile path = do
  child <- forkProcess $ traceChild path
  waitpid child []
  return child

traceChild :: FilePath -> IO ()
traceChild file = do
  ptrace_traceme
  executeFile file False [] Nothing
  trace "EXEC FAILED" $ fail "EXEC FAILED"

testInner :: (CPid -> StateT s IO ()) -> CPid -> StateT s IO ()
testInner act pid = do
  act pid
  lift $ ptrace_singlestep pid Nothing
  (spid, status) <- lift $ waitForRes pid
  if spid == pid
    then case status of W.Stopped _ -> testInner act pid
                        Signaled _ -> testInner act pid
                        Continued -> testInner act pid
                        W.Exited _ -> return ()
    else fail "Wrong pid from waitpid!"

openChildProcMem :: CPid -> IO Handle
openChildProcMem pid = do
  openFile ("/proc/" ++ (show pid) ++ "/mem") ReadWriteMode

readFileOffset :: Handle -> Word64 -> Word64 -> IO B.ByteString
readFileOffset h addr width = do
  hSeek h AbsoluteSeek $ fromIntegral addr
  B.hGet h $ fromIntegral width

printInstr :: Memory Word64 -> CPid -> StateT s IO ()
printInstr mem pid = do
  regs <- lift $ ptrace_getregs pid
  case regs
    of X86 _ -> fail "X86Regs! only 64 bit is handled"
       X86_64 regs64 -> do
         let rip_val = rip regs64
         case readInstruction mem rip_val
           of Left err -> lift $ putStrLn $ "Couldn't disassemble instruction " ++ show err
              Right (ii, nextAddr) -> lift $ putStrLn $ show $ ppInstruction nextAddr ii

translatePtraceRegs :: X86_64Regs -> X86State MS.Value
translatePtraceRegs ptraceRegs =
  mkX86State fillReg
  where
    fillReg :: N.RegisterName cl -> MS.Value (N.RegisterType cl)
    fillReg N.IPReg = mkLit64 (rip ptraceRegs)
    fillReg (N.GPReg 0)  = mkLit64 (rax ptraceRegs)
    fillReg (N.GPReg 1)  = mkLit64 (rcx ptraceRegs)
    fillReg (N.GPReg 2)  = mkLit64 (rdx ptraceRegs)
    fillReg (N.GPReg 3)  = mkLit64 (rbx ptraceRegs)
    fillReg (N.GPReg 4)  = mkLit64 (rsp ptraceRegs)
    fillReg (N.GPReg 5)  = mkLit64 (rbp ptraceRegs)
    fillReg (N.GPReg 6)  = mkLit64 (rsi ptraceRegs)
    fillReg (N.GPReg 7)  = mkLit64 (rdi ptraceRegs)
    fillReg (N.GPReg 8)  = mkLit64 (r8 ptraceRegs)
    fillReg (N.GPReg 9)  = mkLit64 (r9 ptraceRegs)
    fillReg (N.GPReg 10) = mkLit64 (r10 ptraceRegs)
    fillReg (N.GPReg 11) = mkLit64 (r11 ptraceRegs)
    fillReg (N.GPReg 12) = mkLit64 (r12 ptraceRegs)
    fillReg (N.GPReg 13) = mkLit64 (r13 ptraceRegs)
    fillReg (N.GPReg 14) = mkLit64 (r14 ptraceRegs)
    fillReg (N.GPReg 15) = mkLit64 (r15 ptraceRegs)
    fillReg (N.SegmentReg 0) = mkLit16 (es ptraceRegs)
    fillReg (N.SegmentReg 1) = mkLit16 (cs ptraceRegs)
    fillReg (N.SegmentReg 2) = mkLit16 (ds ptraceRegs)
    fillReg (N.SegmentReg 3) = mkLit16 (ss ptraceRegs)
    fillReg (N.SegmentReg 4) = mkLit16 (fs ptraceRegs)
    fillReg (N.SegmentReg 5) = mkLit16 (gs ptraceRegs)
    fillReg (N.FlagReg n) = Literal $ bitVector knownNat $ bitVec 1
                            (if testBit (eflags ptraceRegs) n
                               then 1
                               else 0 :: Int)
    fillReg (N.ControlReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg (N.X87ControlReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg (N.X87StatusReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg N.X87TopReg = Undefined $ BVTypeRepr  knownNat
    fillReg N.X87PC = Undefined $ BVTypeRepr  knownNat
    fillReg N.X87RC = Undefined $ BVTypeRepr  knownNat
    fillReg (N.X87TagReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg (N.X87FPUReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg (N.XMMReg _) = Undefined $ BVTypeRepr  knownNat
    fillReg (N.DebugReg _) = Undefined $ BVTypeRepr  knownNat

    mkLit16 :: Word64 -> MS.Value (BVType 16)
    mkLit16 = Literal . bitVector knownNat . bitVec 16
    mkLit64 :: Word64 -> MS.Value (BVType 64)
    mkLit64 = Literal . bitVector knownNat . bitVec 64

data FileByteReader a = FileByteReader (Handle -> IO a)

instance Functor FileByteReader where
  fmap f (FileByteReader g) = FileByteReader (\h -> fmap f $ g h)

instance Monad FileByteReader where
  (>>=) (FileByteReader f) g  = FileByteReader $ \h -> do
    x <- f h
    let FileByteReader g_ = g x
    g_ h
  return = pure

instance Applicative FileByteReader where
  pure x = FileByteReader (\_ -> return x)
  (<*>) = ap

instance ByteReader FileByteReader where
  readByte = FileByteReader $ \h -> fmap (flip B.index 0) (B.hGet h 1)

runFileByteReader :: FileByteReader a -> Handle -> IO a
runFileByteReader (FileByteReader f) h = f h

printRegsAndInstrProcMem :: Handle -> CPid -> StateT s IO ()
printRegsAndInstrProcMem procMem pid = do
  regs <- liftIO $ ptrace_getregs pid
  case regs
    of X86 _ -> fail "X86Regs! only 64 bit is handled"
       X86_64 regs64 -> do
         lift $ putStrLn $ show {-$ pretty $ translatePtraceRegs-} regs64
         let rip_val = rip regs64
         lift $ hSeek procMem AbsoluteSeek $ fromIntegral rip_val
         ii <- lift $ runFileByteReader (disassembleInstruction defaultX64Disassembler) procMem
         nextAddr <- lift $ fmap fromIntegral $ hTell procMem
         lift $ putStrLn $ show $ ppInstruction nextAddr ii


newtype PTraceMachineState a = PTraceMachineState {unPTraceMachineState ::
   ReaderT PTraceInfo IO a}
   deriving (Monad, MonadReader PTraceInfo, MonadIO)

data PTraceInfo = PTraceInfo {cpid :: CPid, memHandle :: Handle, mapHandle :: Handle}

instance MonadMachineState PTraceMachineState where
  setMem = fail "unimplemented"
  getMem (Address width bv) = do
    memH <- asks memHandle
    bs <- liftIO $ readFileOffset memH  (fromIntegral $ nat $ snd $ unBitVector bv) (fromIntegral $ widthVal width)
    return $ Literal $ toBitVector width bs

  getReg regname = do
    regs <- dumpRegs
    return $ regs^.(register regname)
  setReg = fail "unimplemented"
  dumpRegs = do
     pid <- asks cpid
     regs <-liftIO $ ptrace_getregs pid
     case regs of
       X86_64 regs' -> return $ translatePtraceRegs regs'
       _ -> fail "64-bit only!"

instance FoldableMachineState PTraceMachineState where

  foldMem8 f x= do
    memH <- asks memHandle
    mapH <- asks mapHandle
    memMap <- liftIO $ exploreMem memH mapH
    return $ Map.foldrWithKey f x memMap


toBitVector :: NatRepr n -> B.ByteString -> BitVector n
toBitVector n bs =
  bitVector n $ bitVec (widthVal n) (B.foldr (\b acc -> acc*(2^(8::Integer)) + fromIntegral b) (0::Integer) bs)

exploreMem :: Handle -> Handle -> IO (Map Address8 MS.Value8)
exploreMem memH mapH =
  exploreInner memH mapH Map.empty
  where
    exploreInner memH mapH acc = do
      line <- hGetLine mapH
      let (s1, rest) = splitFirst '-' line
      let (s2, _) = splitFirst ' ' rest
      a1 <- case readHex s1 of ((a1, _) : _) -> return a1
                               _ -> fail "couldn't parse /proc/pid/map"
      a2 <- case readHex s2 of ((a2, _) : _) -> return a2
                               _ -> fail "couldn't parse /proc/pid/map"
      acc' <- loadMem memH acc a1 a2
      ready <- hReady mapH
      if ready then exploreInner memH mapH acc else return acc'
    splitFirst c (c' : rest)
      | c == c' = ([], rest)
      | otherwise = case splitFirst c rest of (l1, l2) -> (c : l1, l2)
    splitFirst c [] = ([], [])

loadMem :: Handle
        -> Map Address8 MS.Value8
        -> Integer
        -> Integer
        -> IO (Map Address8 MS.Value8)
loadMem memH map start stop = do
  hSeek memH AbsoluteSeek start
  buf <- B.hGet memH $ fromInteger $ stop - start
  return $ populateMap map start buf
  where
    populateMap map start buf =
      if B.null buf
      then map
      else populateMap
             (Map.insert
               (Address n8 $ bitVector n64 $ bitVec 64 start)
               (Literal $ bitVector n8 $ bitVec 8 (B.head buf))
               map)
             (start + 1)
             (B.tail buf)

printRegsAndInstr :: Memory Word64 -> CPid -> StateT s IO ()
printRegsAndInstr mem pid = do
  regs <- lift $ ptrace_getregs pid
  case regs
    of X86 _ -> fail "X86Regs! only 64 bit is handled"
       X86_64 regs64 -> do
         lift $ putStrLn $ show $ {- pretty $ translatePtraceRegs -} regs64
         let rip_val = rip regs64
         case readInstruction mem rip_val
           of Left err -> lift $ putStrLn "Couldn't find instruction at address "
              Right (ii, nextAddr) -> lift $ putStrLn $ show $ ppInstruction nextAddr ii

waitForRes :: CPid -> IO (CPid, Status)
waitForRes pid = do
  res <- waitpid pid []
  case res of Just x -> return x
              Nothing -> waitForRes pid

main :: IO ()
main = do
  args <- getCommandLineArgs
  case args^.reoptAction of
    Test -> test args
    Instr -> printExecutedInstructions args
    ShowHelp ->
      print $ helpText [] HelpFormatDefault arguments
    ShowVersion ->
      putStrLn (modeHelp arguments)