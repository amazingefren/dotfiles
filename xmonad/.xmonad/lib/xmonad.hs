import XMonad
import XMonad.Hooks.EwmhDesktops
import XMonad.Hooks.ManageDocks
import XMonad.Hooks.DynamicLog
import XMonad.Util.Run(spawnPipe, hPutStrLn)
import XMonad.Layout.Spacing
import XMonad.Layout.NoBorders
import XMonad.Layout.LayoutModifier (LayoutModifier(modifyLayout), ModifiedLayout)
import XMonad.Layout.Renamed (Rename(Replace), renamed)
import XMonad.Layout.ResizableTile (ResizableTall(ResizableTall))
import XMonad.Util.EZConfig(additionalKeys)

import Data.Monoid
import System.Exit
import qualified Data.Map as M
import qualified XMonad.StackSet as W


myFocusFollowsMouse :: Bool
myClickJustFocuses :: Bool

myModMask     = mod4Mask
myFocusFollowsMouse = True
myClickJustFocuses = False

myWorkspaces    = ["1","2","3","4","5","6","7","8","9"]
myBorderWidth = 2

myNormalBorderColor  = "#212121"
myFocusedBorderColor = "#E47C67"

myTerminal    = "alacritty"
myBar         = "killall xmobar; xmobar"

myKeys conf@XConfig {XMonad.modMask = modm} = M.fromList $
    -- launch a terminal
    [ ((modm .|. shiftMask, xK_Return), spawn $ XMonad.terminal conf)
    -- launch dmenu
    , ((modm,               xK_p     ), spawn "dmenu_run")
    -- close focused window
    , ((modm .|. shiftMask, xK_c     ), kill)
     -- Rotate through the available layout algorithms
    , ((modm,               xK_space ), sendMessage NextLayout)
    --  Reset the layouts on the current workspace to default
    , ((modm .|. shiftMask, xK_space ), setLayout $ XMonad.layoutHook conf)
    -- Resize viewed windows to the correct size
    , ((modm,               xK_n     ), refresh)
    -- Move focus to the next window
    , ((modm,               xK_Tab   ), windows W.focusDown)
    -- Move focus to the next window
    , ((modm,               xK_j     ), windows W.focusDown)
    -- Move focus to the previous window
    , ((modm,               xK_k     ), windows W.focusUp  )
    -- Move focus to the master window
    , ((modm,               xK_m     ), windows W.focusMaster  )
    -- Swap the focused window and the master window
    , ((modm,               xK_Return), windows W.swapMaster)
    -- Swap the focused window with the next window
    , ((modm .|. shiftMask, xK_j     ), windows W.swapDown  )
    -- Swap the focused window with the previous window
    , ((modm .|. shiftMask, xK_k     ), windows W.swapUp    )
    -- Shrink the master area
    , ((modm,               xK_h     ), sendMessage Shrink)
    -- Expand the master area
    , ((modm,               xK_l     ), sendMessage Expand)
    -- Push window back into tiling
    , ((modm,               xK_t     ), withFocused $ windows . W.sink)
    -- Increment the number of windows in the master area
    , ((modm              , xK_comma ), sendMessage (IncMasterN 1))
    -- Deincrement the number of windows in the master area
    , ((modm              , xK_period), sendMessage (IncMasterN (-1)))
    -- Toggle the status bar gap
    , ((modm              , xK_b     ), sendMessage ToggleStruts)
    -- Quit xmonad
    , ((modm .|. shiftMask, xK_q     ), io exitSuccess)
    -- Restart xmonad
    , ((modm .|. shiftMask, xK_r     ), spawn "xmonad --recompile && xmonad --restart")
    -- Volume Controls by XEV as specified at /usr/include/X11/XF86keysym.h
    , ((0                     , 0x1008FF11), spawn "amixer -q sset Master 5%-")
    , ((0                     , 0x1008FF13), spawn "amixer -q sset Master 5%+")
    , ((0                     , 0x1008FF12), spawn "amixer set Master toggle")
    ]
    ++
    -- mod-[1..9], Switch to workspace N mod-shift-[1..9], Move client to workspace N
    [((m .|. modm, k), windows $ f i)
        | (i, k) <- zip (XMonad.workspaces conf) [xK_ampersand, xK_bracketleft, xK_braceleft, xK_braceright, xK_parenleft
                                                 ,xK_equal, xK_asterisk, xK_parenright, xK_plus, xK_bracketright, xK_exclam]
        , (f, m) <- [(W.greedyView, 0), (W.shift, shiftMask)]]

    -- mod-{w,e,r}, Switch to physical/Xinerama screens 1, 2, or 3
    -- mod-shift-{w,e,r}, Move client to screen 1, 2, or 3
    -- [((m .|. modm, key), screenWorkspace sc >>= flip whenJust (windows . f))
    --     | (key, sc) <- zip [xK_w, xK_e, xK_r] [0..]
    --     , (f, m) <- [(W.view, 0), (W.shift, shiftMask)]]

mySpacing :: Integer -> l a -> XMonad.Layout.LayoutModifier.ModifiedLayout Spacing l a
mySpacing i = spacingRaw True (Border 0 i 0 i) True (Border i 0 i 0) True

myTall = renamed [Replace "Tall"]
  $ avoidStruts
  $ smartBorders 
  $ mySpacing 10
  $ ResizableTall 1 (3/100) (1/2) []

myTallMirror = renamed [Replace "Mirrored Tall"]
  $ avoidStruts
  $ smartBorders
  $ mySpacing 10
  $ Mirror 
  $ Tall 1 (3/100) (1/2)

myFull = renamed [Replace "Full"]
  $ avoidStruts
  $ smartBorders
  Full
  
myLayout = 
  myTall 
  ||| myTallMirror 
  ||| myFull


main = do 

  xmproc <- spawnPipe myBar

  xmonad $ ewmh $ docks def {
    terminal    = myTerminal,
    modMask     = myModMask,

    focusFollowsMouse = myFocusFollowsMouse,
    clickJustFocuses  = myClickJustFocuses,
    workspaces        = myWorkspaces,

    borderWidth = myBorderWidth,
    normalBorderColor = myNormalBorderColor,
    focusedBorderColor = myFocusedBorderColor,

    layoutHook  = myLayout,
    logHook = dynamicLogWithPP $ xmobarPP { ppOutput = hPutStrLn xmproc},
    manageHook  = manageHook def <+> manageDocks,
    startupHook = do spawn "~/.xmonad/autostart",

    keys        = myKeys
  }
