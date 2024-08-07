module Evaluator where
import Values
import Control.Monad.Except
import Variables
import Data.Maybe (isNothing)
import GHC.IO.IOMode
import GHC.IO.Handle
import System.IO
import Parser

ioPrimitives :: [(String, [Values] -> IOThrowsError Values)]
ioPrimitives = [("apply", applyProc),
                ("open-input-file", makePort ReadMode),
                ("open-output-file", makePort WriteMode),
                ("close-input-port", closePort),
                ("close-output-port", closePort),
                ("read", readProc),
                ("write", writeProc),
                ("read-contents", readContents),
                ("read-all", readAll)]

makePort :: IOMode -> [Values] -> IOThrowsError Values
makePort mode [String filename] = fmap Port $ liftIO $ openFile filename mode
makePort _ _ = throwError $ Default "Whoops! There is an unknown error!"

closePort :: [Values] -> IOThrowsError Values
closePort [Port port] = liftIO $ hClose port >> return (Bool True)
closePort _           = return $ Bool False

readProc :: [Values] -> IOThrowsError Values
readProc []          = readProc [Port stdin]
readProc [Port port] = liftIO (hGetLine port) >>= liftThrows . readExpr
readProc _           = throwError $ Default "Whoops! There is an unknown error!"

writeProc :: [Values] -> IOThrowsError Values
writeProc [obj]            = writeProc [obj, Port System.IO.stdout]
writeProc [obj, Port port] = liftIO $ hPrint port obj >> return (Bool True)
writeProc _                = throwError $ Default "Whoops! There is an unknown error!"

applyProc :: [Values] -> IOThrowsError Values
applyProc [func, List args] = apply func args
applyProc (func : args)     = apply func args
applyProc _                 = throwError $ Default "Whoops! There is an unknown error!"

readContents :: [Values] -> IOThrowsError Values
readContents [String filename] = fmap String $ liftIO $ readFile filename
readContents _ = throwError $ Default "Whoops! There is an unknown error!"

load :: String -> IOThrowsError [Values]
load filename = liftIO (readFile filename) >>= liftThrows . readExprList

readAll :: [Values] -> IOThrowsError Values
readAll [String filename] = List <$> load filename
readAll _ = throwError $ Default "Whoops! There is an unknown error!"

apply :: Values -> [Values] -> ExceptT Errors IO Values
apply (PrimitiveFunc func) args = liftThrows $ func args
apply (Func fparams varargs fbody fclosure) args =
     if num fparams /= num args && isNothing varargs
          then throwError $ ArgumentNumber (num fparams) args
          else liftIO (bindVars fclosure $ zip fparams args) >>= bindVarArgs varargs >>= evalBody
     where remainingArgs = drop (length fparams) args
           num = toInteger . length
           evalBody env = last <$> mapM (evaluateExpr env) fbody
           bindVarArgs arg env = case arg of
                Just argName -> liftIO $ bindVars env [(argName, List remainingArgs)]
                Nothing -> return env
apply (IOFunc func) args = func args
apply _ _ = throwError $ Default "Whoops! There is an unknown error!"

makeFunc :: Monad m => Maybe String -> IOEnvironment -> [Values] -> [Values] -> m Values
makeFunc varargs env fparams fbody = return $ Func (map showValue fparams) varargs fbody env
makeNormalFunc :: IOEnvironment -> [Values] -> [Values] -> ExceptT Errors IO Values
makeNormalFunc = makeFunc Nothing
makeVarArgs :: Values -> IOEnvironment -> [Values] -> [Values] -> ExceptT Errors IO Values
makeVarArgs = makeFunc . Just . showValue

evaluateExpr :: IOEnvironment -> Values -> IOThrowsError Values
evaluateExpr _ val@(String _) = return val
evaluateExpr _ val@(Number _) = return val
evaluateExpr env (Atom fid) = getVar env fid
evaluateExpr _ val@(Bool _) = return val
evaluateExpr _ (List [Atom "quote", val]) = return val
evaluateExpr env (List [Atom "if", p, c, a]) =
     do result <- evaluateExpr env p
        case result of
             Bool False -> evaluateExpr env a
             _  -> evaluateExpr env c
evaluateExpr env (List [Atom "set!", Atom var, form]) = evaluateExpr env form >>= setVar env var
evaluateExpr env (List [Atom "define", Atom var, form]) = evaluateExpr env form >>= defineVar env var
evaluateExpr env (List (Atom "define" : List (Atom var : fparams) : fbody)) = makeNormalFunc env fparams fbody >>= defineVar env var
evaluateExpr env (List (Atom "define" : ImproperList (Atom var : fparams) varargs : fbody)) = makeVarArgs varargs env fparams fbody >>= defineVar env var
evaluateExpr env (List (Atom "lambda" : List fparams : fbody)) = makeNormalFunc env fparams fbody
evaluateExpr env (List (Atom "lambda" : ImproperList fparams varargs : fbody)) = makeVarArgs varargs env fparams fbody
evaluateExpr env (List (Atom "lambda" : varargs@(Atom _) : fbody)) = makeVarArgs varargs env [] fbody
evaluateExpr env (List [Atom "load", String filename]) = load filename >>= fmap last . mapM (evaluateExpr env)

evaluateExpr env (List (func : args)) = do
     f <- evaluateExpr env func
     argVals <- mapM (evaluateExpr env) args
     apply f argVals

evaluateExpr _ badForm = throwError $ BadSpecialForm "Unrecognized special form" badForm