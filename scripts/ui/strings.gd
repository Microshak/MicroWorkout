class_name Strings
extends RefCounted
## Every fixed user-visible sentence PRD-06 owns, in one file — R8/R10/R12.
##
## Two reasons this is a class and not inline literals: the privacy note is a **contract** (it
## tells the owner exactly where the key lives, and the device screenshots are diffed against
## it), and a later copy review is one file instead of nine screens.

## R8 — the privacy note. Format string whose single `%s` is the package id; render it with
## [method privacy_note] rather than interpolating by hand, so a debug build names its own
## package (`…debug`) and the Android path in the text is never wrong.
const PRIVACY_NOTE := "MicroWorkout stores your API key only in this app's private on-device \
storage (user://data/settings.json — on Android that is \
/data/data/%s/files/data/settings.json). Other apps cannot read it. The key is never baked into \
the app, never written to a log, never included in an error message or crash report, and never \
sent anywhere except the provider you selected above. Requests go straight from this phone to \
that provider — MicroWorkout has no server of its own and no analytics. If you skip this step, \
MicroWorkout builds your plans on-device with its built-in generator. You can add a key later in \
Settings → AI provider, and you can erase it at any time with Settings → Reset all data."

const PRIVACY_HEADING := "Your API key stays on this phone"

# ------------------------------------------------------------------ onboarding (R4)

const WELCOME_TITLE := "MicroWorkout"
const WELCOME_PROMISE := "Plans built for you, sessions you can follow at the rack, and a \
streak you can keep. Five quick questions and you are ready to train."
const WELCOME_FOOTNOTE := "Built for one person: you."
const UNITS_QUESTION := "Which units do you lift in?"
const UNITS_EXAMPLE_PREFIX := "Bench Press — 3 × 8 @ "
const THEME_QUESTION := "Dark or light?"
const GOAL_QUESTION := "How many days a week do you want to train?"
const LLM_QUESTION := "Want an AI to write your plans?"
const DONE_TITLE := "You're set."
const DONE_HINT := "Generate your first plan from the Home tab."
const SKIP_BUTTON := "Skip — use the built-in generator"

# ------------------------------------------------------------------ settings (R10/R11/R12)

const SETTINGS_TITLE := "Settings"
const UNITS_SECTION := "Units"
const THEME_SECTION := "Theme"
const WEEKLY_GOAL_SECTION := "Weekly goal"
const REST_TIMER_SECTION := "Rest timer"
const FEEDBACK_SECTION := "Feedback"
const AI_SECTION := "AI provider"
const PLAN_SECTION := "Plan"
const STORAGE_SECTION := "Storage"
const ATTRIBUTION_SECTION := "Attribution"
const ABOUT_SECTION := "About"
const DANGER_SECTION := "Danger zone"
const STORAGE_HINT := "Files live in this app's private storage; they are removed when you \
uninstall."
const MEDICAL_DISCLAIMER := "Form tips are general guidance, not medical advice."
## The §7.1 evidence sources, shown in the About card so the guidance has a provenance.
const EVIDENCE_SOURCES := "Plan guidance is based on Mayo Clinic strength-training guidance, \
the Stronger By Science complete strength training guide, and USA Weightlifting's science of \
weightlifting."
const REST_STEP_HINT := "Rest defaults are used when a workout block does not set its own."
const GOAL_FROM_PLAN_HINT := "Set by your active plan — edit the plan to change it."
const PLAN_ACTIVE_HINT := "Your plans and history are never touched by this."
const DARK_LABEL := "Dark"
const LIGHT_LABEL := "Light"
const REST_VIBRATE_LABEL := "Vibrate when rest ends"
const REST_SOUND_LABEL := "Beep when rest ends"
const TEXT_SIZE_LABEL := "Text size"
const TEXT_SIZE_HINT := "Applies to every screen right away."
const PLAN_REGENERATE_BUTTON := "Regenerate default plan"
const PLAN_REGENERATE_CONFIRM := "Replace your current default plan with a freshly generated \
one? Your workout history is not touched."
const ATTRIBUTION_BUTTON := "Exercise art and licence"
const RESET_BUTTON := "Reset all data"
const RESET_TITLE := "Erase everything?"
const RESET_BODY := "This deletes your workout plan, your entire history, your streak, and your \
saved API key.\nIt cannot be undone."
const RESET_PLACEHOLDER := "Type RESET to confirm"
const RESET_WARNING := "This is permanent. Type RESET exactly to enable the button."
const RESET_OK := "Erase all data"
const RESET_CANCEL := "Keep my data"
## The exact word the user must type (R12). Case-sensitive, trailing whitespace ignored.
const RESET_WORD := "RESET"
const TAB_HINT := "Open the Settings tab to change units, theme, or your weekly goal."

# ------------------------------------------------------------------ provider block (R6/R7/R9)

const PROVIDER_LABEL := "Provider"
const BASE_URL_LABEL := "Base URL"
const MODEL_LABEL := "Model"
const API_KEY_LABEL := "API key"
const BASE_URL_FIXED_HINT := "Fixed for this provider"
const SHOW_KEY := "Show"
const HIDE_KEY := "Hide"
const HELP_BUTTON := "Provider docs"
const TEST_BUTTON := "Test connection"
const SAVE_AI_BUTTON := "Save"
const CUSTOM_AUTH_NONE := "This server needs no API key"
const CUSTOM_JSON_MODE := "Server supports JSON mode"
const STATUS_VERIFIED := "Verified"
const STATUS_UNVERIFIED := "Not verified"
const STATUS_REJECTED := "Key rejected"
const STATUS_UNREACHABLE := "Unreachable"
const TEST_UNAVAILABLE := "Connection testing arrives with the plan generator; your settings \
were saved."

# ------------------------------------------------------------------ toasts (R10/R12)

const TOAST_AI_SAVED := "AI settings saved."
const TOAST_PLAN_REGENERATED := "Default plan regenerated."
const TOAST_ALL_DATA_ERASED := "All data erased."
const TOAST_SETTING_SAVED := "Saved."
const TOAST_SAVE_FAILED := "Could not save that — try again."


## The R8 note with this build's package id filled in.
static func privacy_note() -> String:
	return PRIVACY_NOTE % package_id()


## `com.microshak.microworkout.debug` in a debug build, so the path the note shows is the path
## the running app actually writes to.
static func package_id() -> String:
	return AppInfo.PACKAGE_ID_DEBUG if OS.is_debug_build() else AppInfo.PACKAGE_ID
