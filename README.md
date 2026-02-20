# Holmes - Zero Prompt AI for macOS

A sleek, macOS-native AI assistant with an iOS 26 Liquid Glass aesthetic and global hotkey access.

## Overview

Holmes is a zero-prompt AI assistant designed for macOS that brings AI capabilities to your fingertips with a beautiful, modern interface. Access it instantly from anywhere with a simple keyboard shortcut.

## Recent Updates (February 2026)

### Major UI/UX Improvements

#### 🎨 iOS 26 Liquid Glass Aesthetic
- **Advanced Glass Morphism**: Multi-layer blur effects with `VisualEffectBlur` for authentic glass material
- **Refined Gradients**: Teal/gray-green color scheme (RGB: 0.3, 0.38, 0.38) with radial lighting
- **Film Grain Texture**: Subtle overlay at 3-4% opacity for premium feel
- **Sleeker Design**: Reduced button sizes by ~30%, tighter spacing, refined typography (11-18pt range)
- **Clean Borders**: Gradient stroke overlays with 0.5px lineWidth for sharp definition

#### ⌨️ Fixed Global Hotkey
- **Control+Space**: Now works globally from anywhere, not just when menu bar is selected
- **Switched to Carbon API**: More reliable global hotkey registration using `HotkeyManager`
- **Consistent Activation**: Works across all spaces and full-screen apps

#### 🎬 Smooth Transitions
- **Dynamic Window Resizing**: Automatically animates from 140px → 280px when showing response
- **Fluid State Changes**: Spring animations (0.4-0.5s response, 0.85 damping) throughout
- **Clean Appearance**: Removed blur artifacts and shadow glitches from glass transitions
- **Back Navigation**: Smooth transition back to search input with chevron button

#### 🪟 Movable Window
- **Drag Anywhere**: Click and drag the window to reposition on screen
- **Constraint Fix**: Resolved NSException errors during window movement
- **Resize Protection**: Prevents conflicts between user drag and programmatic resize
- **Smart Hiding**: Window doesn't auto-dismiss while being dragged

#### 🎯 UI Refinements
- **Brand Integration**: Holmes logo from SVG assets replaces generic sparkle icon
- **Consistent Theming**: Both search and response use matching teal glass background
- **Back Button**: Added chevron navigation to return from response to search
- **Blank Response State**: Ready for LLM integration with placeholder text
- **Reset Behavior**: Properly returns to search input when closing, not response state

#### 🔧 Technical Improvements
- **Window Management**: Enhanced `SearchBarWindowController` with drag tracking and resize locking
- **State Management**: Improved `SearchViewModel` with `goBackToSearch()` method
- **Panel Behavior**: Custom `SearchBarPanel` with mouse event tracking for drag detection
- **Shadow Removal**: Eliminated all unwanted shadows with `invalidateShadow()` and layer opacity controls

### Authentication System
- **Clerk Integration**: Full authentication flow with `ClerkAuthManager` and `ClerkConfig`
- **Keychain Storage**: Secure session token management with `KeychainManager`
- **Login Window**: Beautiful glass-styled login interface
- **Session Validation**: Automatic token validation on app launch

### Project Cleanup
- **Removed Web Files**: Deleted Next.js website directory, keeping only native macOS app
- **Focused Codebase**: Holmes iOS app in SwiftUI only
- **Asset Organization**: Logo and icon assets properly integrated into Xcode project

## Features

### Current
- ⚡ **Global Hotkey Access**: Control+Space from anywhere
- 🎨 **iOS 26 Liquid Glass UI**: Premium blur effects and animations
- 🪟 **Movable Window**: Drag to reposition anywhere on screen
- 🔐 **Secure Authentication**: Clerk-based login with keychain storage
- 🎯 **Smooth Transitions**: Fluid animations between states
- 🎨 **Film Grain Effects**: Subtle texture for visual depth

### Coming Soon
- 🤖 **LLM Integration**: Connect your preferred AI model
- 🎤 **Voice Input**: Speech-to-text with audio level visualization
- 📊 **Context Awareness**: Screen recording and accessibility permissions for smart assistance
- 🔔 **Notch Animations**: Dynamic island-style notifications (for MacBooks with notch)

## Tech Stack

- **SwiftUI**: Modern declarative UI framework
- **AppKit**: Native macOS window management
- **Carbon API**: Global hotkey registration
- **Clerk**: Authentication and user management
- **Keychain Services**: Secure credential storage
- **Speech Framework**: Voice input (coming soon)
- **AVFoundation**: Audio processing (coming soon)

## Installation

1. Clone the repository:
```bash
git clone https://github.com/Noir-Zero-Prompt-AI/Frontend-UI.git
cd Frontend-UI/holmes
```

2. Open in Xcode:
```bash
open holmes.xcodeproj
```

3. Build and run (⌘R)

## Usage

1. **Launch Holmes**: Open the app from Applications or Xcode
2. **Complete Onboarding**: First-time setup wizard
3. **Login**: Authenticate with Clerk
4. **Access Anywhere**: Press `Control+Space` to summon the search bar
5. **Ask Questions**: Type your query and press Enter or click the arrow button
6. **View Response**: AI response appears with smooth transition
7. **Go Back**: Click the chevron button or press Escape

## Keyboard Shortcuts

- `Control+Space`: Open search bar
- `Option+Space`: Open assistant panel
- `Command+\`: Toggle side icon
- `Escape`: Close/go back

## Project Structure

```
holmes/
├── App/
│   ├── holmesApp.swift          # App entry point
│   ├── AppDelegate.swift        # Hotkey setup, auth flow
│   └── Permissions.swift        # System permissions
├── Core/
│   ├── HotkeyManager.swift      # Global hotkey registration
│   ├── MenuBarManager.swift     # Menu bar controls
│   ├── ClerkAuthManager.swift   # Authentication
│   └── KeychainManager.swift    # Secure storage
├── Views/
│   ├── SearchBar/               # Main search interface
│   │   ├── SearchBarView.swift
│   │   ├── SearchBarWindow.swift
│   │   └── SearchViewModel.swift
│   ├── Login/                   # Auth screens
│   ├── Onboarding/              # First-run experience
│   └── MainPanel/               # Assistant panel
├── Components/
│   ├── GlassCard.swift          # Reusable glass UI
│   ├── NoirTextField.swift      # Custom input field
│   └── GrainOverlay.swift       # Film grain effect
└── Design/
    ├── NoirColors.swift         # Color palette
    └── NoirFonts.swift          # Typography
```

## Design System

### Colors (Liquid Glass)
- **Search/Response Background**: Teal-Gray (RGB: 0.3, 0.38, 0.38, opacity: 0.85-0.9)
- **Radial Highlights**: Lighter teal (RGB: 0.35, 0.43, 0.43, opacity: 0.12)
- **Button Backgrounds**: White (opacity: 0.08)
- **Border Strokes**: White gradient (0.15 → 0.05, lineWidth: 0.5)
- **Text**: White (opacity: 0.75-0.95)

### Typography
- **Brand Name**: 18pt Semibold Monospaced
- **Labels**: 11-13pt Medium
- **Body**: 13-15pt Regular
- **Placeholders**: 11pt Regular

### Spacing
- **Padding**: 16-20px (reduced from 24px)
- **Button Spacing**: 12-16px
- **Element Gaps**: 16px vertical

### Components
- **Buttons**: 28-30px icons, 8-10px text padding
- **Corners**: 16-24px continuous radius
- **Input Fields**: 10-14px padding, 16px radius

## Contributing

This is a private repository for the Holmes project. For collaboration inquiries, please contact the team.

## License

Proprietary - All rights reserved

## Credits

Developed by the Noir Zero Prompt AI team
Design inspired by iOS 26 Liquid Glass aesthetic

---

**Version**: 1.0.0  
**Last Updated**: February 20, 2026  
**macOS Requirement**: 14.0+  
**Swift Version**: 5.x
