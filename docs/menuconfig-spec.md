# COMPLETE SPECIFICATION

CLI Configuration Interface
Simple, friendly, efficient – for experienced users

---

## 1. Purpose

Provide a CLI interface to **view and modify configuration** using:

* clear menu navigation,
* actions triggered by **selecting a line**,
* **automatic behavior based on value type**,
* no modes, no commands to memorize, no ambiguity.

---

## 2. Core Principle

> **The user selects a line.
> The system decides what action to perform based on the value type.**

The user:

* never chooses an action type,
* never switches modes,
* never needs to learn syntax.

---

## 3. General Interface

### 3.1 Menu Title

* The word `MENU` is **never shown**
* The **menu title** is always shown
* The title represents the **functional path**

**Format:**

```
<Configuration Presets / default / Flags>
```

---

### 3.3 Display metaphor

Every menu simply shows where you are and what you can act on:

```
Config > Presets > default > Flags

  1) ENABLE_RRD      ON
  2) ENABLE_SNMP     OFF
  3) ENABLE_IPV6     ON
  b) Back
```

The menu’s only job is to display context and available actions; navigation keys stay minimal and consistent across all tools.

### 3.4 Supplemental context

Short, read-only context blocks (e.g., tables that summarize sources/presets) may appear immediately before the numbered menu when they help orient the user, but they must remain static and non-interactive. The layout that follows still consists of a single title line, the numbered actions, and `b) Back`; the supplemental block simply provides extra orientation without becoming a “mode” or an extra list.

### 3.2 Screen Layout (single, consistent layout)

```
<Menu title>

  1) <item 1>
  2) <item 2>
  ...
  b) Back
```

* Same layout at all levels
* Context is immediately clear

---

## 4. Navigation

### 4.1 Rules

* Navigation is only for **orientation**
* No decorative screens
* Every menu provides at least one real action
* `b` always returns to the previous menu
* Any supplemental context block must stay read-only; navigation still happens exclusively through the numbered menu.

---

### 4.2 Hierarchy

* Menus are hierarchical
* Functional depth only (minimum 3 real levels)
* No artificial levels

---

## 5. Data Model (Value Types)

Each displayed line represents **one typed element**.

Supported types:

1. `boolean`
2. `enum` (predefined options)
3. `string`
4. `path`
5. `editor` (complex edit: file or block)

---

## 6. Behavior by Type (key rule)

### 6.1 Boolean

**Display**

```
  2) ENABLE_SNMP     OFF
```

**User action**

* Select the line (`2`)

**System behavior**

* Immediate toggle

**Result**

```
ENABLE_SNMP -> ON
```

* No submenu
* No prompt
* Menu is redisplayed

---

### 6.2 Enum (multiple options)

**Display**

```
  1) BUILD_TYPE   Release
```

**User action**

* Select the line

**System behavior**

* Automatically opens a choice menu

**Display**

```
<Select BUILD_TYPE>

  1) Debug
  2) Release
  3) RelWithDebInfo
  b) Back
```

**Result**

```
BUILD_TYPE -> Debug
```

* Automatic return to parent menu

---

### 6.3 String

**Display**

```
  1) PROJECT_NAME   xymon
```

**User action**

* Select the line

**System behavior**

* Direct input prompt

**Prompt**

```
New value :
```

**Result**

```
PROJECT_NAME updated
```

---

### 6.4 Path

**Display**

```
  1) PREFIX   /usr/local
```

**User action**

* Select the line

**System behavior**

* Direct input prompt

**Prompt**

```
New path :
```

**Result**

```
PREFIX updated
```

* Same flow as `string`
* Silent validation

---

### 6.5 Editor (complex content)

**Display**

```
  1) cmake-local.conf
```

**User action**

* Select the line

**System behavior**

* Opens the configured editor
* On exit, returns to the same menu

---

## 7. Validation Rules

* Validation is automatic and type-based
* On error:

  * short message
  * value unchanged
  * return to the current menu

No interactive validation dialogs.

---

## 8. Saving

* Changes are applied immediately in memory
* Persistence may be:

  * automatic, or
  * triggered by a dedicated action
* Behavior is consistent and predictable

---

## 9. UX Rules (strict)

* No modes
* No command syntax
* No confirmations except for destructive actions
* Always return to the current menu
* Same behavior everywhere

---

## 10. What the User Instantly Understands

* The **title** shows where they are
* The **number** performs an action
* The **displayed value** is the real value
* The system adapts to the value type

When the user selects **Edit cmake-local.conf**, the same typed rules apply: booleans toggle immediately, enums drop into a choice menu, strings and paths prompt for direct input, and “editor” entries launch the configured handler. The menu redraws in place so there is never an “edit mode,” and every submenu (including the top-level explore menu) clearly prints `Choice [q]:` before waiting for input to keep the cursor on the right line.

---

## 11. Final Summary

> **Select a line.
> The system does the right thing.**

This specification is:

* complete,
* coherent,
* simple,
* friendly,
* directly implementable.

If needed next, this can be extended with:

* a formal `type → action` decision table,
* a data schema,
* or validation against real use cases.

## 12. Execution flow

The bootstrap runner (`cmake-local.sh` / `Runner.pm`) prints the explore menu, handles `Choice [q]:`, and simply starts the helper script you picked (config editor, preset editor, etc.). Every helper script must reuse `CMakeLocal::ConfigMenu` and obey the same “title/path + numbered entries + `b) Back`” metaphor so the UI is consistent no matter which process is running. This keeps the top-level launcher minimal while letting each helper render its own spec-compliant menu.

## 13. Consistency reminders

* Always re-evaluate transient state before rendering a menu. For example, the explore menu now rescans `CMakePresets.user.json` on each redraw so the “missing/empty” warning matches the current filesystem state.
* Keep duplicated-state guards in sync with the in-memory model (see `cmake-local/bin/cmake-presets-editor.pl::preset_exists_in_memory`). Don’t rely on disk reads alone when a preset can be added, cloned or removed within the same session.
* Document these expectations here so helper authors know which guards must stay in place whenever they change the CLI.
