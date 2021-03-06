{-# LANGUAGE ViewPatterns #-}

module Tool where

import Data.Hex
import Data.List
import Data.Char
import qualified Data.ByteString.Char8 as BS

import Control.Monad
import Control.Exception

import System.Exit

import Tucker.Conf
import Tucker.Util
import Tucker.Error
import Tucker.Table
import Tucker.Console

import Tucker.Wallet.Wallet
import Tucker.Wallet.Mnemonic

import Flag

type ToolProc = Tool -> [String] -> [Flag] -> [String] -> IO ()

data Tool
    = ToolGroup {
        group_name :: String,
        group_desc :: String,
        group_list :: [Tool]
    }
    
    | Tool {
        tool_name :: String,
        tool_desc :: String,
        tool_args :: [String], -- description for arguments
        tool_proc :: ToolProc,
        tool_opts :: [Option Flag]
    }

toolName (ToolGroup { group_name = name }) = name
toolName (Tool { tool_name = name }) = name

toolDesc (ToolGroup { group_desc = desc }) = desc
toolDesc (Tool { tool_desc = desc }) = desc

toolArgs (ToolGroup {}) = ["<subtool>"]
toolArgs (Tool { tool_args = args }) = args

root_tool =
    ToolGroup "tool" "root tool group" [
        ToolGroup "wallet" "wallet utilities" [
            Tool {
                tool_name = "new",
                tool_desc = "generate a wallet from a mnemonic sentence",
                tool_args = [ "<mnemonic>", "[password]" ],
                tool_proc = toolWalletNew,
                tool_opts = [ opt_chain_path, opt_wallet_path, opt_help ]
            }
        ],

        ToolGroup "mnemonic" "mnemonic utilities(BIP 32)" [
            Tool {
                tool_name = "from-entropy",
                tool_desc = "generate a mnemonic sentence using the given entropy(in hex)",
                tool_args = [ "<entropy in hex>" ],
                tool_proc = toolMnemonicFromEntropy,
                tool_opts = [ opt_help ]
            },

            Tool {
                tool_name = "to-entropy",
                tool_desc = "converse a mnemonic sentence back to the entropy",
                tool_args = [ "<mnemonic>" ],
                tool_proc = toolMnemonicToEntropy,
                tool_opts = [ opt_help ]
            }
        ]
    ]

parseError tool path msg = do
    tLnM msg
    tLnM ""
    showToolHelp tool path

    exitWith (ExitFailure 1)
    
showToolHelp tool@(ToolGroup { group_list = group }) path = do
    tLnM (unwords path ++ ": " ++ toolDesc tool)
    showHelp path (toolArgs tool) []

    let col0_cont = "subtool"
        max_len = foldl max (length col0_cont) $ map (length . toolName) group
        col0_len = max_len + 3

    tLnM ""

    tM (table def [
            "subtool" : map toolName group,
            "description" : map toolDesc group
        ])

showToolHelp tool@(Tool { tool_opts = opts }) path = do
    tLnM (unwords path ++ ": " ++ toolDesc tool)
    showHelp path (toolArgs tool) opts

execTool :: Tool -> [String] -> [String] -> IO ()
execTool tool@(Tool {
    tool_proc = proc,
    tool_opts = opts
}) path args = do
    case parseFlags args opts of
        Right (flags, non_opt) ->
            if ShowHelp `elem` flags then
                showToolHelp tool path
            else
                proc tool path flags non_opt

        Left err -> do
            tLnM (show err)
            tLnM ""
            showToolHelp tool path

execTool tool@(ToolGroup {}) path args =
    case args of
        subtool@(isOption -> False):rst ->
            case first ((== subtool) . toolName) (group_list tool) of
                Just tool -> execTool tool (path ++ [subtool]) rst

                Nothing ->
                    parseError tool path
                               ("failed to find subtool '" ++ subtool ++
                                "' in tool group '" ++ unwords path ++ "'")

        _ ->
            parseError tool path
                       ("expecting subtool specified for tool group '" ++ unwords path ++ "'")

findAndExecTool :: [String] -> IO ()
findAndExecTool args = execTool root_tool ["tool"] args

-- tool procs

toolWalletNew tool path flags (sent:rst) = do
    conf <- flagsToConf flags
    newWalletFromMnemonic
        conf (words sent)
        (case rst of [] -> Nothing; [pass] -> Just pass)

toolWalletNew tool path _ _ =
    showToolHelp tool path

toolMnemonicFromEntropy tool path flags (entropy:_) =
    case entropyToMnemonic def (hex2bs entropy) of
        Right words -> tLnM (unwords words)
        Left err -> throw err

toolMnemonicFromEntropy tool path _ _ =
    showToolHelp tool path

toolMnemonicToEntropy tool path flags (mnemonic:_) =
    case mnemonicToEntropy def (words mnemonic) of
        Right ent -> tLnM (map toLower (BS.unpack (hex ent)))
        Left err -> throw err

toolMnemonicToEntropy tool path _ _ =
    showToolHelp tool path
