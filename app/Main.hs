module Main where
import Parser
import Evaluator
import System.Environment (getArgs)

main :: IO ()
main = getArgs >>= print . evaluate . readExpr . head