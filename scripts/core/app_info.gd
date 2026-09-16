class_name AppInfo
extends RefCounted
## Single source of truth for app identity and version.
##
## Nothing in the codebase should hardcode the app name, version, or package id —
## read them from here so PRD-13 (release) only has to change one file.

const NAME := "MicroWorkout"
const VERSION := "0.1.0"
const VERSION_CODE := 1
const PACKAGE_ID := "com.microshak.microworkout"
const PACKAGE_ID_DEBUG := "com.microshak.microworkout.debug"

## The design resolution every screen is laid out against (portrait).
const DESIGN_WIDTH := 1080
const DESIGN_HEIGHT := 1920

## Minimum splash duration, so a fast boot does not flash the splash screen.
const MIN_SPLASH_SECONDS := 0.9
