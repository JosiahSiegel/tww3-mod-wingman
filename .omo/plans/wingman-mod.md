# Wingman TWW3 Mod Work Plan

## Context

**User Request Summary**: Build a complete implementation plan for a Total War: Warhammer III Steam Workshop mod named **Wingman** that lets the player hand campaign/battle control to AI-like automation and enforce custom rules such as turn caps, win conditions, faction restrictions, and periodic breakpoints. The user prefers leveraging the game's existing AI-for-factions behavior rather than simulating it from scratch.

**Locked architecture**:
- Pack name: `!wingman.pack`.
- Required dependency: MCT, Workshop ID `2927955021`.
- No `cm:set_faction_human`; do not attempt ownership flip.
- Campaign handover is simulated with `cm:end_turn()` and `FactionTurnStart` orchestration while the player slot remains human.
- Battle handover uses scripted AI planner / alliance AI plan APIs, with optional instant autoresolve.
- Persistence: `core:svr_save_registry_string` for cross-restart global settings, `cm:save_named_value` for savegame state.
- Mission framework: `mission_manager:set_turn_limit()`, `add_payload("game_victory")`, scripted objectives.
- Patch resilience: public documented APIs only, `pcall` around risky calls, MCT/mod-load guards.
- MP guard: every entry point exits when `cm:is_multiplayer()` is true.
- Safety-critical: handle diplomacy popup race and battle-result popup dismissal.

**User-confirmed design decisions (post-research)**:
- **UI tone**: Co-pilot / playful. "Wingman taking the stick", "I'll handle this turn", "Heads up — war declaration, pausing so you can react." Friendly, fits the mod name.
- **Faction bans**: Proper UI for everything. **NO CSV strings**. Use MCT `ControlGroup.Array` + `OnPopulate` + per-faction `MCT.Option.Checkbox` pattern (Pattern A from MCT research). The settings panel populates the faction list dynamically from `cm:model():world():faction_manager()` when opened. Each banned faction is its own toggle.
- **Turn cap default**: Breakpoint (return control to player). User can change to victory in settings if desired.
- **Battle handover modes** (4 explicit user options):
  1. **Auto-resolve if favorable** — Wingman checks `cm:pending_battle_cache_human_victory()` (etc.) and triggers autoresolve via `pending_battle` interception if odds favor us; otherwise pauses for player choice.
  2. **Pause and let player choose** — every battle prompts player; safest.
  3. **Always fight manually** — Wingman observes but never auto-decides battles; player retains full control.
  4. **AI fights the battle** (default if handover enabled) — scripted AI planner takes over player alliance in battle.
- **Custom UI folder skipped**: MCT provides the settings UI.

**TDD approach**:
- Each feature ships with log-observable scenario checks before polish.
- Runtime verification is in-game/manual because WH3 campaign/battle APIs are not available outside the game.
- Static QA uses Lua parse/lint/format tools only if installed; in-game script logs are the source of truth.

### File Manifest

| File | Purpose | Key exports/functions | Dependencies / load-order notes |
|---|---|---|---|
| `.gitignore` | Exclude local agent/runtime/build outputs. | N/A | Should exclude `.omo/run-continuation/`, local logs, temp pack exports; keep `.omo/plans/wingman-mod.md` tracked if desired. |
| `.luarc.json` | Configure Lua 5.1 / sumneko workspace for TWW3 globals. | N/A | Depends on no source files. |
| `selene.toml` | Optional Lua lint rules. | N/A | Must allow WH3 globals: `cm`, `core`, `bm`, `mission_manager`. |
| `stylua.toml` | Optional Lua formatting rules. | N/A | Lua 5.1-compatible style. |
| `README.md` | User-facing overview, dependency, install, safety caveats. | N/A | Depends on final feature set. |
| `CHANGELOG.md` | Release history and Workshop update notes source. | N/A | Start with `0.1.0-alpha`. |
| `WORKSHOP.md` | Upload checklist, tags, dependency, thumbnail rules. | N/A | Depends on packaging workflow. |
| `script/mct/settings/wingman_mct.lua` | MCT option registration and settings adapter. | `wingman_mct.register_settings()`, `wingman_mct.read_settings()`, `wingman_mct.validate_settings()` | MCT loads this path. Runtime must tolerate MCT unavailable and log hard dependency message. |
| `script/campaign/mod/wingman_init.lua` | Campaign bootstrap, first-tick init, listener registration. | `wingman.init()`, `wingman.register_listeners()`, `wingman.shutdown()` | Auto-loaded by campaign. Use deferred first-tick callback so module file order is safe. If order bugs appear, rename pack-internal file to `zzz_wingman_init.lua`. |
| `script/campaign/mod/wingman_state.lua` | State machine, persistence, config serialization. | `wingman_state.init()`, `load()`, `save()`, `set_mode()`, `set_breakpoint()` | No internal dependency except `core`/`cm`; other modules depend on it. |
| `script/campaign/mod/wingman_safety.lua` | MP guard, popup safety, risky-call wrappers, recovery mode. | `wingman_safety.mp_guard()`, `safe_call()`, `pause_for_popup()`, `dismiss_battle_result()` | Depends on `wingman_state`; campaign/battle/rules call it before actions. |
| `script/campaign/mod/wingman_rules.lua` | Turn cap, win condition, faction restriction evaluators. | `evaluate_all()`, `evaluate_turn_cap()`, `evaluate_custom_win()`, `evaluate_faction_restrictions()` | Depends on `wingman_state`, `wingman_safety`, MCT settings keys. |
| `script/campaign/mod/wingman_missions.lua` | Mission-manager builders for turn caps and scripted objectives. | `create_turn_cap_mission()`, `create_custom_objective_missions()`, `complete_victory()` | Depends on `wingman_state`, `wingman_rules`, `mission_manager`. |
| `script/campaign/mod/wingman_campaign.lua` | Campaign auto-end-turn driver and breakpoint handling. | `register_listeners()`, `on_faction_turn_start()`, `drive_auto_turn()`, `release_to_player()` | Depends on state, safety, rules, missions, MCT settings. |
| `script/campaign/mod/wingman_battle.lua` | Campaign-side battle detection, pending battle state, result handling. | `register_listeners()`, `on_battle_being_fought()`, `on_battle_completed()`, `queue_battle_handover()` | Depends on state, safety, MCT settings. |
| `script/battle/mod/wingman_battle_init.lua` | Battle-mode takeover: scripted AI control / instant autoresolve. | `wingman_battle_init.init()`, `apply_ai_plan()`, `maybe_end_battle()` | Battle environment only; no `cm`. Reads global registry/settings via `core` where available. |
| `text/db/wingman.loc.tsv` | Source localization for MCT labels/tooltips/log strings. | N/A | Imported/converted by RPFM to `text/db/*.loc` inside pack. |
| `assets/workshop/!wingman.png` | Workshop thumbnail source, 256×256 PNG under 1 MB. | N/A | Must match pack filename when installed/uploaded as `!wingman.png`; verify launcher acceptance. |
| `tests/manual/wingman_scenarios.md` | Manual TDD scenario matrix S1–S10. | N/A | Mirrors Verification Scenarios below. |
| `.omo/plans/wingman-mod.md` | This executable plan. | N/A | Planning artifact only. |

## Task Dependency Graph

| Task | Depends On | Dependents | Reason |
|---|---|---|---|
| T1 Repo scaffold and tooling | None | T2, T3, T8, T9 | Establishes directories, ignore rules, docs/tooling conventions. |
| T2 MCT schema and localization | T1 | T4, T5, T6, T7 | Runtime modules need canonical setting keys and labels. |
| T3 State and safety foundation | T1 | T4, T5, T6, T7 | Every runtime action needs state persistence, MP guard, and safe-call wrappers. |
| T4 Campaign handover driver | T2, T3 | T7, T8, T10 | Implements campaign auto-turn behavior used by scenarios S1/S6/S8. |
| T5 Rules and missions | T2, T3 | T7, T8, T10 | Implements turn caps, custom win checks, and faction restrictions for S3–S5. |
| T6 Battle handover | T2, T3 | T7, T8, T10 | Implements campaign/battle control for S2/S9. |
| T7 Bootstrap integration | T4, T5, T6 | T8, T9, T10 | Wires listeners, first-tick init, module ordering, and cross-module flow. |
| T8 TDD verification suite | T4, T5, T6, T7 | T10 | Converts scenarios into repeatable evidence checks. |
| T9 Packaging and Workshop docs/assets | T7 | T10 | Requires stable pack structure before packaging/publishing docs are final. |
| T10 Final QA and review | T8, T9 | None | Validates all scenarios, smoke workflow, and release readiness. |

## Parallel Execution Graph

Wave 1 — foundation, can start immediately:
├── T1 Repo scaffold and tooling  
├── T2 MCT schema and localization  
└── T3 State and safety foundation  

Wave 2 — feature modules, after Wave 1:
├── T4 Campaign handover driver  
├── T5 Rules and missions  
└── T6 Battle handover  

Wave 3 — integration and verification, after Wave 2:
├── T7 Bootstrap integration  
└── T8 TDD verification suite  

Wave 4 — release prep and final QA, after Wave 3:
├── T9 Packaging and Workshop docs/assets  
└── T10 Final QA and review  

Critical Path: T1 → T3 → T5 → T7 → T10  
Estimated Parallel Speedup: ~45% faster than sequential because T2/T3 and T4/T5/T6 can run independently.

## Tasks

### Task 1: Repo scaffold and tooling

**Description**: Create non-runtime project scaffolding: `.gitignore`, Lua tooling configs, documentation placeholders, source directories, manual test directory, and asset directory.

**Delegation Recommendation**:
- Category: `quick` - mostly single-file scaffolding and convention setup.
- Skills: `[]` - no specialized skill directly applies; no code implementation yet.

**Skills Evaluation**:
- Included: none.
- Omitted `git-master`: no commit requested during implementation.
- Omitted `programming`: task is scaffolding, not source implementation.
- Omitted `frontend`, `playwright`, `visual-qa`: no browser/web UI.
- Omitted `debugging`: no runtime issue yet.
- Omitted `security-research` / `security-review`: not a security audit.
- Omitted `customize-opencode`: not opencode configuration.
- Omitted `ast-grep`, `refactor`, `remove-ai-slops`: no existing source to rewrite.
- Omitted `coding-agent-sessions`, `lcx-*`, `ulw-research`, `ultimate-browsing`, `lsp-setup`, `start-work`, `review-work`: domains do not overlap this atomic task.

**Depends On**: None.

**Acceptance Criteria**:
- Directory skeleton exists for `script/campaign/mod`, `script/battle/mod`, `script/mct/settings`, `text/db`, `assets/workshop`, `tests/manual`.
- `.gitignore` excludes local runtime/log/build artifacts without excluding source `.lua`, `.tsv`, `.md`, or thumbnail source.
- Lua tooling configs recognize Lua 5.1 and TWW3 global names.

### Task 2: MCT schema and localization

**Description**: Implement MCT configuration registration and localization source for all settings listed in the MCT Settings Schema.

**Delegation Recommendation**:
- Category: `unspecified-high` - requires careful integration with an external mod API and fallback behavior.
- Skills: `[]` - no MCT-specific skill exists; use locked research and MCT docs/examples.

**Skills Evaluation**:
- Included: none.
- Omitted `programming`: project code is Lua, while the skill is targeted to Python/Rust/TypeScript/Go.
- Omitted `frontend`: MCT is in-game Lua UI, not web/frontend.
- Omitted `librarian` as skill: not available as load skill; use docs manually if needed.
- Omitted `debugging`: implementation first; runtime debugging only if smoke tests fail.
- Omitted `git-master`, `security-*`, `customize-opencode`, `ast-grep`, `refactor`, `playwright`, `visual-qa`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T1.

**Acceptance Criteria**:
- `script/mct/settings/wingman_mct.lua` defines all schema keys and default values.
- Localization source includes title, option labels, tooltips, warnings, and log-readable setting names.
- Missing MCT logs a clear required-dependency message and disables runtime actions safely.
- Text/CSV settings validate unknown or malformed keys without crashing.

### Task 3: State and safety foundation

**Description**: Implement versioned state machine, persistence keys, MP guard, safe-call wrapper, popup safety hooks, and error-safe mode.

**Delegation Recommendation**:
- Category: `unspecified-high` - cross-cutting runtime foundation that all features depend on.
- Skills: `debugging` - runtime failures, popup races, and save/load defects require debugging discipline.

**Skills Evaluation**:
- Included `debugging`: handles crashes, silent failures, stuck popups, and runtime log diagnosis.
- Omitted `programming`: Lua not covered by that skill’s mandatory domains.
- Omitted `security-review`: safety here is game-state stability, not adversarial security.
- Omitted `git-master`: no git operation.
- Omitted `frontend`, `playwright`, `visual-qa`: no web/browser visual work.
- Omitted `customize-opencode`, `ast-grep`, `refactor`, `remove-ai-slops`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `review-work`, `start-work`: not required for this focused implementation task.

**Depends On**: T1.

**Acceptance Criteria**:
- All public entry points can call `wingman_safety.mp_guard()` and no-op in multiplayer.
- Save/load uses versioned keys and default migration.
- `pcall` wrappers log failures and switch to breakpoint/error-safe mode instead of continuing automation.
- Diplomacy and battle-result popup helpers are callable but conservative by default.

### Task 4: Campaign handover driver

**Description**: Implement `FactionTurnStart`-driven auto-turn behavior, periodic breakpoints, handover enable/disable, and safe release back to player.

**Delegation Recommendation**:
- Category: `unspecified-high` - stateful campaign scripting with race conditions.
- Skills: `debugging` - needed for turn-loop, listener, and popup race validation.

**Skills Evaluation**:
- Included `debugging`: campaign automation can hang, silently fail, or crash; log-driven debugging is essential.
- Omitted `programming`: Lua not in mandatory scope.
- Omitted `frontend`: MCT UI already handled in T2.
- Omitted `security-*`, `git-master`, `customize-opencode`, `ast-grep`, `refactor`, `playwright`, `visual-qa`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T2, T3.

**Acceptance Criteria**:
- Campaign handover can be enabled/disabled through settings/state.
- On player `FactionTurnStart`, rules are evaluated before any `cm:end_turn()` call.
- Periodic breakpoints stop automation and return control.
- Logs include turn number, faction key, rule result, and chosen action.

### Task 5: Rules and missions

**Description**: Implement rule evaluators and mission-manager builders for turn caps, custom win objectives, and faction restriction violations.

**Delegation Recommendation**:
- Category: `unspecified-high` - rule logic touches campaign state, settings, mission APIs, and user-visible outcomes.
- Skills: `debugging` - needed for mission event and rule-trigger diagnosis.

**Skills Evaluation**:
- Included `debugging`: validates event-driven rule triggers and mission completion behavior.
- Omitted `programming`: Lua not covered.
- Omitted `security-review`: no security-sensitive surface.
- Omitted `frontend`: no UI beyond schema already handled.
- Omitted `git-master`, `customize-opencode`, `ast-grep`, `refactor`, `playwright`, `visual-qa`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T2, T3.

**Acceptance Criteria**:
- Turn cap can create/update a mission and trigger configured outcome.
- Custom win conditions support owned-settlement and defeated-faction CSV settings.
- Faction restriction violations pause/warn by default and never destructively modify campaign state unless a future explicit setting is added.
- Each evaluator returns a structured result: `pass`, `breakpoint`, `victory`, `warning`, or `error`.

### Task 6: Battle handover

**Description**: Implement campaign-side battle queue/result handling and battle-mode AI control / instant autoresolve path.

**Delegation Recommendation**:
- Category: `unspecified-high` - spans campaign and battle script environments.
- Skills: `debugging` - battle scripts are runtime-only and need log/evidence loops.

**Skills Evaluation**:
- Included `debugging`: battle control can fail silently or differ by battle context.
- Omitted `frontend`, `visual-qa`: not browser/TUI visual work; in-game screenshots are manual evidence.
- Omitted `programming`: Lua not covered.
- Omitted `security-*`, `git-master`, `customize-opencode`, `ast-grep`, `refactor`, `playwright`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T2, T3.

**Acceptance Criteria**:
- Battle handover setting is read in campaign and battle environments.
- Scripted AI plan applies attack/defend/auto bias safely with `pcall`.
- Instant autoresolve is opt-in only.
- Battle completion queues result dismissal only when safe and logs outcome.

### Task 7: Bootstrap integration

**Description**: Wire all modules through `wingman_init.lua`, first-tick setup, listener registration/removal, MCT settings load, mission initialization, and error-safe shutdown.

**Delegation Recommendation**:
- Category: `unspecified-high` - integration across all runtime files.
- Skills: `debugging` - listener accumulation and init order bugs are runtime failures.

**Skills Evaluation**:
- Included `debugging`: validates first-tick ordering, listener lifecycle, and initialization failures.
- Omitted `programming`: Lua not covered.
- Omitted `git-master`, `security-*`, `frontend`, `playwright`, `visual-qa`, `customize-opencode`, `ast-grep`, `refactor`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T4, T5, T6.

**Acceptance Criteria**:
- New campaign logs exactly one init sequence.
- Reloaded save does not duplicate listeners.
- Missing module/settings path triggers safe mode, not crash.
- MP campaign logs disabled state and registers no automation listeners.

### Task 8: TDD verification suite

**Description**: Create the manual scenario suite, log-evidence checklist, and pass/fail matrix for S1–S10.

**Delegation Recommendation**:
- Category: `writing` - documentation-heavy verification design.
- Skills: `debugging` - scenarios require concrete runtime evidence and failure triage.

**Skills Evaluation**:
- Included `debugging`: evidence capture and failure diagnosis are core to this task.
- Omitted `programming`: no source implementation.
- Omitted `frontend`, `playwright`, `visual-qa`: no browser automation.
- Omitted `git-master`, `security-*`, `customize-opencode`, `ast-grep`, `refactor`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T4, T5, T6, T7.

**Acceptance Criteria**:
- `tests/manual/wingman_scenarios.md` contains S1–S10 with setup, steps, pass condition, evidence.
- Each scenario has at least one binary observable pass condition.
- Evidence paths include `script_log_*.txt`, screenshot name, and savegame checkpoint.

### Task 9: Packaging and Workshop docs/assets

**Description**: Prepare RPFM packaging instructions, thumbnail, README, CHANGELOG, Workshop description checklist, dependency declaration, and upload workflow.

**Delegation Recommendation**:
- Category: `writing` - release documentation and asset checklist.
- Skills: `[]` - no specialized code/review skill needed unless committing.

**Skills Evaluation**:
- Included: none.
- Omitted `git-master`: only needed if user asks to commit/tag release.
- Omitted `frontend`, `visual-qa`: image asset is static and manually inspected.
- Omitted `debugging`: runtime QA is T10.
- Omitted `programming`, `security-*`, `customize-opencode`, `ast-grep`, `refactor`, `playwright`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `review-work`, `start-work`: not directly applicable.

**Depends On**: T7.

**Acceptance Criteria**:
- README lists MCT dependency and MP disabled behavior.
- CHANGELOG has initial alpha entry.
- WORKSHOP checklist includes original launcher upload path and excludes EA Mod Manager upload.
- `assets/workshop/!wingman.png` is 256×256 PNG and under 1 MB.

### Task 10: Final QA and review

**Description**: Run static checks if available, package/import via RPFM, execute smoke workflow, run scenarios S1–S10, and review implementation against locked architecture.

**Delegation Recommendation**:
- Category: `unspecified-high` - multi-step validation across tools and runtime environments.
- Skills: `review-work`, `debugging` - post-implementation review and runtime failure diagnosis.

**Skills Evaluation**:
- Included `review-work`: required after significant implementation to verify goal, code quality, security/safety, QA, and context.
- Included `debugging`: needed for any failed in-game smoke/scenario.
- Omitted `git-master`: only needed if user explicitly asks for commits.
- Omitted `frontend`, `playwright`, `visual-qa`: no browser UI.
- Omitted `programming`: Lua not covered by that skill.
- Omitted `security-research` / `security-review`: not a security audit unless requested.
- Omitted `customize-opencode`, `ast-grep`, `refactor`, `coding-agent-sessions`, `lcx-*`, `ulw-*`, `ultimate-browsing`, `lsp-setup`, `remove-ai-slops`, `start-work`: not directly applicable to final QA.

**Depends On**: T8, T9.

**Acceptance Criteria**:
- Static checks pass or unavailable tools are documented.
- RPFM import/install succeeds.
- New IE campaign loads with MCT dependency enabled.
- S1–S10 pass or each failure has a blocking bug entry with log evidence.
- Final review confirms no direct `cm:set_faction_human` attempt, no custom UI folder, MP guard at every entry, and safety wrappers around risky calls.

## Per-file Implementation Outline

### `script/mct/settings/wingman_mct.lua`

**Public functions**:
- `wingman_mct.register_settings()` — register all MCT options under the Wingman mod panel.
- `wingman_mct.read_settings()` — return validated runtime settings table.
- `wingman_mct.validate_settings(settings)` — clamp numeric values and sanitize CSV keys.
- `wingman_mct.get_default_settings()` — return schema defaults when MCT is unavailable.
- `wingman_mct.is_available()` — detect MCT safely.

**Listener registrations**:
- None directly required. Runtime reads settings on first tick and on player `FactionTurnStart`.
- If MCT exposes a stable documented settings-changed callback in the installed version, add it only after verifying exact API name.

**Persistence keys**:
- `core:svr_save_registry_string("wingman.v1.global_settings", serialized_settings)`
- No `cm:save_named_value` in this file.

**MCT settings keys**:
- All keys listed in the MCT Settings Schema.

### `script/campaign/mod/wingman_init.lua`

**Public functions**:
- `wingman.init()` — entry point called from campaign first tick.
- `wingman.register_listeners()` — delegates listener registration to campaign, battle, safety, and missions modules.
- `wingman.unregister_listeners()` — removes all Wingman listeners before re-registering.
- `wingman.shutdown(reason)` — disables automation and saves safe state.

**Listener registrations**:
- First-tick callback: condition campaign loaded and not MP; callback `wingman.init`.
- No direct campaign event listeners beyond delegating to modules.

**Persistence keys**:
- Reads/writes via `wingman_state`.
- Logs init version to `cm:save_named_value("wingman.v1.last_init_version", "0.1.0-alpha")`.

**MCT settings keys**:
- `wingman_enabled`
- `wingman_debug_logging`

### `script/campaign/mod/wingman_state.lua`

**Public functions**:
- `wingman_state.init()` — initialize defaults and migrate saved state.
- `wingman_state.load()` — load savegame state and global config.
- `wingman_state.save()` — persist current state.
- `wingman_state.get_mode()` — return `disabled`, `campaign_handover`, `breakpoint`, or `error_safe`.
- `wingman_state.set_mode(mode, reason)` — update mode and save.
- `wingman_state.set_breakpoint(reason, data)` — pause automation and preserve reason.
- `wingman_state.get_settings()` — current validated settings.
- `wingman_state.update_settings(settings)` — replace settings and save global copy.
- `wingman_state.mark_turn_processed(turn_number)` — prevent repeated auto-end loops.

**Listener registrations**:
- None directly.

**Persistence keys**:
- `core:svr_save_registry_string("wingman.v1.global_settings", payload)`
- `core:svr_save_registry_string("wingman.v1.last_error", message)`
- `cm:save_named_value("wingman.v1.schema_version", 1)`
- `cm:save_named_value("wingman.v1.mode", mode)`
- `cm:save_named_value("wingman.v1.campaign_enabled", bool)`
- `cm:save_named_value("wingman.v1.battle_enabled", bool)`
- `cm:save_named_value("wingman.v1.last_processed_turn", number)`
- `cm:save_named_value("wingman.v1.break_reason", string)`
- `cm:save_named_value("wingman.v1.rule_progress", serialized_progress)`
- `cm:save_named_value("wingman.v1.pending_battle", serialized_battle_state)`
- `cm:save_named_value("wingman.v1.mission_keys", serialized_mission_keys)`

**MCT settings keys**:
- Reads all settings through `wingman_mct.read_settings()`.

### `script/campaign/mod/wingman_safety.lua`

**Public functions**:
- `wingman_safety.mp_guard(entry_name)` — returns false and logs when multiplayer is active.
- `wingman_safety.safe_call(label, fn)` — wraps risky calls with `pcall`.
- `wingman_safety.pause_for_popup(panel_key)` — create breakpoint for unsafe modal panels.
- `wingman_safety.dismiss_battle_result_if_safe()` — try to dismiss result popup conservatively.
- `wingman_safety.enter_error_safe_mode(reason)` — disable automation and save reason.
- `wingman_safety.is_modal_blocking()` — detect known blocking UI panels.

**Listener registrations**:
- `PanelOpenedCampaign`: condition panel key matches diplomacy/result/known modal panels; callback `pause_for_popup`.
- `ComponentLClickUp`: condition result-panel continue button clicked; callback clear pending result state.
- `BattleCompleted`: condition campaign automation or auto-dismiss enabled; callback schedule safe result dismissal.

**Persistence keys**:
- `cm:save_named_value("wingman.v1.break_reason", reason)`
- `cm:save_named_value("wingman.v1.last_safety_event", event_payload)`
- `core:svr_save_registry_string("wingman.v1.last_error", message)`

**MCT settings keys**:
- `wingman_safety_level`
- `wingman_break_on_diplomacy_panel`
- `wingman_break_on_war_declaration`
- `wingman_auto_dismiss_battle_results`
- `wingman_debug_logging`

### `script/campaign/mod/wingman_rules.lua`

**Public functions**:
- `wingman_rules.evaluate_all(context)` — evaluate all enabled rules and return highest-priority result.
- `wingman_rules.evaluate_turn_cap(context)` — detect turn cap reached.
- `wingman_rules.evaluate_custom_win(context)` — detect custom win objectives complete.
- `wingman_rules.evaluate_faction_restrictions(context)` — detect banned-faction/restriction violation.
- `wingman_rules.parse_key_csv(value, kind)` — sanitize user CSV keys.
- `wingman_rules.describe_result(result)` — human/log-readable rule outcome.

**Listener registrations**:
- None directly; called by campaign driver.
- Optional `FactionTurnStart` rule listener only if integration prefers separate listener; otherwise avoid duplicate evaluation.

**Persistence keys**:
- `cm:save_named_value("wingman.v1.rule_progress", serialized_progress)`
- `cm:save_named_value("wingman.v1.last_rule_result", serialized_result)`

**MCT settings keys**:
- `wingman_turn_cap_enabled`
- `wingman_turn_cap_value`
- `wingman_turn_cap_outcome`
- `wingman_custom_win_enabled`
- `wingman_required_settlements_csv`
- `wingman_required_defeated_factions_csv`
- `wingman_faction_restrictions_enabled`
- `wingman_banned_factions_csv`
- `wingman_restriction_violation_action`

### `script/campaign/mod/wingman_missions.lua`

**Public functions**:
- `wingman_missions.init_for_faction(faction_key)` — create/update missions for current settings.
- `wingman_missions.create_turn_cap_mission(faction_key, turn_limit)` — build mission with turn limit.
- `wingman_missions.create_custom_objective_missions(faction_key, objectives)` — create scripted objectives.
- `wingman_missions.complete_victory(faction_key, reason)` — trigger `game_victory` payload when configured.
- `wingman_missions.cancel_or_refresh()` — clean stale mission keys after setting changes.

**Listener registrations**:
- `MissionSucceeded`: condition Wingman mission key; callback update state/log.
- `MissionFailed`: condition Wingman mission key; callback update state/log.

**Persistence keys**:
- `cm:save_named_value("wingman.v1.mission_keys", serialized_mission_keys)`
- `cm:save_named_value("wingman.v1.rule_progress", serialized_progress)`

**MCT settings keys**:
- `wingman_turn_cap_enabled`
- `wingman_turn_cap_value`
- `wingman_turn_cap_outcome`
- `wingman_custom_win_enabled`
- `wingman_required_settlements_csv`
- `wingman_required_defeated_factions_csv`

### `script/campaign/mod/wingman_campaign.lua`

**Public functions**:
- `wingman_campaign.register_listeners()` — add campaign listeners after safety/state init.
- `wingman_campaign.on_faction_turn_start(context)` — main player-turn automation entry.
- `wingman_campaign.drive_auto_turn(context)` — evaluate rules and call `cm:end_turn()` if safe.
- `wingman_campaign.release_to_player(reason)` — stop automation and surface breakpoint.
- `wingman_campaign.should_auto_end_turn(faction)` — guard and setting check.
- `wingman_campaign.schedule_end_turn(delay_seconds)` — delayed forced end-turn wrapper.

**Listener registrations**:
- `FactionTurnStart`: condition `context:faction():is_human()` and Wingman campaign enabled; callback `on_faction_turn_start`.
- `FactionTurnEnd`: condition human faction; callback save state and clear transient flags.
- `WorldStartRound` or equivalent round-start event if available: condition Wingman enabled; callback refresh MCT settings and missions.
- `PanelOpenedCampaign`: safety callback delegated to `wingman_safety`.

**Persistence keys**:
- `cm:save_named_value("wingman.v1.last_processed_turn", turn_number)`
- `cm:save_named_value("wingman.v1.mode", mode)`
- `cm:save_named_value("wingman.v1.break_reason", reason)`

**MCT settings keys**:
- `wingman_enabled`
- `wingman_campaign_handover_enabled`
- `wingman_auto_end_turn_delay_seconds`
- `wingman_periodic_break_interval`
- `wingman_break_on_diplomacy_panel`
- `wingman_break_on_war_declaration`
- `wingman_break_on_pending_battle`

### `script/campaign/mod/wingman_battle.lua`

**Public functions**:
- `wingman_battle.register_listeners()` — campaign-side battle listeners.
- `wingman_battle.on_battle_being_fought(context)` — record pending handover when battle starts.
- `wingman_battle.on_battle_completed(context)` — clear battle state and request result dismissal.
- `wingman_battle.queue_battle_handover(battle_context)` — serialize battle preference for battle environment.
- `wingman_battle.clear_pending_battle()` — reset pending battle persistence.

**Listener registrations**:
- `BattleBeingFought`: condition battle handover enabled and not MP; callback `on_battle_being_fought`.
- `BattleCompleted`: condition pending Wingman battle; callback `on_battle_completed`.
- `PanelOpenedCampaign`: condition battle-result panel; callback delegated safety dismissal path.

**Persistence keys**:
- `cm:save_named_value("wingman.v1.pending_battle", serialized_battle_state)`
- `cm:save_named_value("wingman.v1.last_battle_result", serialized_result)`
- `core:svr_save_registry_string("wingman.v1.global_settings", payload)` for battle-environment readable settings.

**MCT settings keys**:
- `wingman_battle_handover_enabled`
- `wingman_battle_control_mode`
- `wingman_battle_plan_bias`
- `wingman_auto_dismiss_battle_results`

### `script/battle/mod/wingman_battle_init.lua`

**Public functions**:
- `wingman_battle_init.init()` — battle-mode bootstrap.
- `wingman_battle_init.read_battle_settings()` — load global settings from registry/defaults.
- `wingman_battle_init.apply_ai_plan()` — force attack/defend/auto plan for player alliance.
- `wingman_battle_init.maybe_end_battle()` — call instant autoresolve only when explicitly configured.
- `wingman_battle_init.log_battle_state()` — write evidence lines for S2/S9.

**Listener registrations**:
- Battle manager callback after battle script init: condition battle handover enabled; callback `apply_ai_plan`.
- Battle manager delayed callback: condition instant autoresolve enabled; callback `maybe_end_battle`.
- Battle completion callback if available: condition Wingman controlled battle; callback log result.

**Persistence keys**:
- Reads `core:svr_save_registry_string("wingman.v1.global_settings")`.
- No `cm:save_named_value`; `cm` is unavailable in battle.

**MCT settings keys**:
- `wingman_battle_handover_enabled`
- `wingman_battle_control_mode`
- `wingman_battle_plan_bias`
- `wingman_debug_logging`

## MCT Settings Schema

UI tone is **co-pilot / playful**. All tooltips and section titles use plain, friendly language with the Wingman persona ("Wingman", "I'll handle this", "Heads up", "Taking the stick"). Settings panel organized into 4 sections: **General**, **Campaign Handover**, **Rules**, **Battle Handover**.

| Section | Key | Type | Default | Range / Options | Validation | Tooltip description (co-pilot voice) |
|---|---:|---:|---|---|---|---|
| General | `wingman_enabled` | boolean | `false` | `true/false` | Must be true before any automation runs. | "Take the stick — let me handle your turns." Master switch. |
| General | `wingman_debug_logging` | boolean | `false` | `true/false` | Always allow essential logs even when false. | "Show me my work" — verbose logs for troubleshooting. |
| General | `wingman_safety_level` | enum | `conservative` | `conservative`, `balanced`, `permissive` | Unknown value falls back to conservative. | "How careful should I be?" — affects popup handling aggressiveness. |
| Campaign Handover | `wingman_campaign_handover_enabled` | boolean | `false` | `true/false` | Ignored unless master enabled. | "Play your campaign for you — I'll auto-end your turns so AI factions take over." |
| Campaign Handover | `wingman_auto_end_turn_delay_seconds` | integer | `2` | `0–10` | Clamp to range; non-number becomes default. | "Wait N seconds before ending your turn — gives UI time to settle so I don't crash on popups." |
| Campaign Handover | `wingman_periodic_break_interval` | integer | `10` | `0–100` | `0` disables; clamp otherwise. | "Every N turns, hand back to you for a quick review. Set to 0 to never break." |
| Campaign Handover | `wingman_break_on_diplomacy_panel` | boolean | `true` | `true/false` | Conservative default true. | "Pause when a diplomacy panel pops up — those tend to crash if I click blindly." |
| Campaign Handover | `wingman_break_on_war_declaration` | boolean | `true` | `true/false` | Conservative default true. | "Pause when war is declared on you — let you handle the alert." |
| Campaign Handover | `wingman_break_on_pending_battle` | boolean | `true` | `true/false` | If false, defer to battle handover settings. | "Pause when a battle needs your decision." |
| Battle Handover | `wingman_battle_handover_enabled` | boolean | `false` | `true/false` | Ignored in MP. | "Take over your battles." Master battle switch. |
| Battle Handover | `wingman_battle_control_mode` | enum | `scripted_ai` | `scripted_ai`, `autoresolve_if_favorable`, `pause_to_choose`, `manual_observe` | Unknown value becomes `scripted_ai`. | "How should I handle battles? `scripted_ai` = I fight for you. `autoresolve_if_favorable` = autoresolve when odds favor us, else pause. `pause_to_choose` = always ask. `manual_observe` = I just watch." |
| Battle Handover | `wingman_battle_plan_bias` | enum | `auto` | `auto`, `attack`, `defend` | Unknown value becomes `auto`. | "When I fight for you, what style? `auto` = let the AI decide. `attack` = aggressive. `defend` = hold and counter." |
| Battle Handover | `wingman_autoresolve_threshold` | percent | `60` | `0–100` | Clamp to range. Used when mode = `autoresolve_if_favorable`. | "Only autoresolve if our win chance is above this % (checked via `pending_battle_cache_human_victory`). Below it, pause instead." |
| Battle Handover | `wingman_auto_dismiss_battle_results` | boolean | `true` | `true/false` | Only attempts dismissal when safety checks pass. | "Auto-dismiss the post-battle results screen so I can keep your campaign moving." |
| Rules | `wingman_turn_cap_enabled` | boolean | `false` | `true/false` | Ignored unless campaign handover enabled. | "Set a hard turn limit. When reached, I hand control back to you (or declare victory — see next option)." |
| Rules | `wingman_turn_cap_value` | integer | `50` | `1–500` | Clamp to range. | "The turn number to cap at. Triggers the outcome you choose below." |
| Rules | `wingman_turn_cap_outcome` | enum | `breakpoint` | `breakpoint`, `victory` | Default breakpoint. | "What happens at the turn cap. `breakpoint` = stop and return control. `victory` = end the campaign with the official victory screen." |
| Rules | `wingman_custom_win_enabled` | boolean | `false` | `true/false` | Requires at least one objective populated when true. | "Enable a custom victory condition I track for you." |
| Rules | `wingman_required_settlements_csv` | string | `""` | Comma-separated settlement/region keys | Trim, lower-case, allow `[a-z0-9_]+`; unknown keys log warning and are ignored. | "Settlements/regions you must own to win. Comma-separated, e.g. `wh_main_altdorf,wh_main_kislev`." |
| Rules | `wingman_required_defeated_factions_csv` | string | `""` | Comma-separated faction keys | Trim, lower-case, allow `[a-z0-9_]+`; unknown keys log warning and are ignored. | "Factions that must be destroyed for victory." |
| Rules | `wingman_faction_restrictions_enabled` | boolean | `false` | `true/false` | No action unless enabled. | "Watch for banned factions — if you confederate or inherit one, I'll warn you." |
| Rules | `wingman_restriction_violation_action` | enum | `warn_pause` | `warn_pause`, `pause_disable` | No destructive action in v0.1. | "What to do on a restriction violation. `warn_pause` = alert and stop. `pause_disable` = disable Wingman entirely." |

### Faction ban list (dynamic UI, NOT a CSV)

The banned-factions list is **not** a setting key — it's a dynamic UI built with `MCT.ControlGroup.Array` + per-faction `MCT.Option.Checkbox`. Populated at panel-open time from `cm:model():world():faction_manager()`. Pattern from [`chadvandy/mct_wh3 — script/mct/settings/mct_testing.lua`](https://github.com/chadvandy/mct_wh3/blob/764a38abb0a6cbe9c92f351e446c8e033e86793d/script/mct/settings/mct_testing.lua):

```lua
-- In wingman_mct.lua (Pattern A)
local array_class    = mct:get_object_type("control_groups", "array")
local checkbox_class = mct:get_mct_option_class_subtype("checkbox")
local ban_array = array_class:new()
ban_array:set_key("wingman_banned_factions")

function wingman_mct:rebuild_ban_list()
    ban_array:clear()  -- if available; else rebuild
    local fm = cm:model():world():faction_manager()
    for i = 0, fm:num_factions() - 1 do
        local f = fm:faction_at(i)
        local cb = checkbox_class:new(self, "ban_" .. f:name())
        cb:set_text(f:get_name() .. " (" .. f:name() .. ")")  -- display name + key tooltip
        cb:set_tooltip_text(f:name())
        ban_array:add_control(cb, i + 1)
    end
end

function page:OnPopulate(uic)
    local col = find_uicomponent(uic, "settings_column_1")
    local box = find_uicomponent(col, "list_clip", "list_box")
    wingman_mct:rebuild_ban_list()
    ban_array:display(box)
end
```

Runtime reads bans back via the saved MCT options (each `ban_<key>` checkbox has its own saved value):

```lua
local function get_banned_factions()
    local banned = {}
    for _, opt in ipairs(wingman_mod:get_section_by_key("rules"):get_options()) do
        local key = opt:get_key()
        if key:match("^ban_") and opt:get_finalized_setting() == true then
            table.insert(banned, key:gsub("^ban_", ""))
        end
    end
    return banned
end
```

This satisfies the user's "UI for everything" requirement — no CSV editing, no manual key typing.

## Verification Scenarios

### S1 — Campaign handover happy path

- **Setup**: New Immortal Empires single-player campaign, stable vanilla faction such as Reikland, MCT enabled, Wingman enabled.
- **Steps**:
  1. Enable `wingman_enabled`.
  2. Enable `wingman_campaign_handover_enabled`.
  3. Set delay to `2`.
  4. End the current player turn once.
  5. Observe next player `FactionTurnStart`.
- **Pass condition**: No crash; log shows `campaign_handover enabled`, `FactionTurnStart`, `rules pass`, `cm:end_turn requested`; player turn advances without manual input.
- **Evidence**: `script_log_*.txt` lines with `[Wingman] S1`, screenshot of campaign turn counter after auto-advance, savegame after one auto turn.

### S2 — Battle handover happy path

- **Setup**: Single-player campaign with a small manual battle available; Wingman master enabled; battle handover enabled; control mode `scripted_ai`; plan bias `auto`.
- **Steps**:
  1. Start battle manually.
  2. Do not issue unit orders after deployment.
  3. Let Wingman battle script initialize.
- **Pass condition**: No crash; log shows battle settings loaded and AI plan applied; units begin acting without player orders or instant autoresolve.
- **Evidence**: `script_log_*.txt` battle lines, screenshot during battle with player units moving/fighting, post-battle save.

### S3 — Turn-cap rule edge

- **Setup**: New or existing IE campaign; campaign handover enabled; turn cap enabled.
- **Steps**:
  1. Set `wingman_turn_cap_value = 3` for test speed.
  2. Set `wingman_turn_cap_outcome = breakpoint`.
  3. Let automation reach turn 3.
- **Pass condition**: On player turn 3, state becomes `breakpoint`; log shows `turn_cap reached`; no `cm:end_turn()` is called after breakpoint.
- **Evidence**: log line, screenshot of turn 3 with player control restored, savegame showing breakpoint state.

### S4 — Custom win condition happy path

- **Setup**: IE campaign where player already owns a known settlement/region key verified in RPFM.
- **Steps**:
  1. Enable custom win.
  2. Set `wingman_required_settlements_csv` to an already owned settlement/region key.
  3. Start next player turn or force settings refresh.
- **Pass condition**: Rule evaluator returns `victory` or mission objective completed according to configured outcome; log shows objective key and completion.
- **Evidence**: script log, mission/objective UI screenshot if visible, savegame after rule completion.

### S5 — Faction ban edge

- **Setup**: IE campaign; player faction key known.
- **Steps**:
  1. Enable faction restrictions.
  2. Put the current player faction key into `wingman_banned_factions_csv`.
  3. Set violation action to `warn_pause`.
  4. Start next player turn.
- **Pass condition**: State becomes `breakpoint`; log shows `faction restriction violation`; no destructive campaign API is called.
- **Evidence**: log line, screenshot of restored control, savegame with `break_reason`.

### S6 — Save/load persistence regression

- **Setup**: IE campaign after S1 has enabled handover and processed at least one auto turn.
- **Steps**:
  1. Save game while Wingman is enabled.
  2. Exit to desktop.
  3. Relaunch with same mod set.
  4. Load save.
- **Pass condition**: Settings and mode restore; no duplicate listeners; next player turn logs one and only one automation sequence.
- **Evidence**: before/after logs, savegame name, screenshot of MCT settings after reload.

### S7 — Workshop/local install regression

- **Setup**: Clean local install path with `!wingman.pack`, `!wingman.png`, and MCT enabled.
- **Steps**:
  1. Install pack through RPFM or copy to TWW3 `data`.
  2. Launch original Total War launcher.
  3. Tick MCT and Wingman.
  4. Start IE campaign.
- **Pass condition**: Campaign loads; MCT Wingman panel appears; log shows init ok; no missing dependency crash.
- **Evidence**: launcher screenshot, MCT panel screenshot, `script_log_*.txt`.

### S8 — Diplomacy safety edge

- **Setup**: Campaign handover enabled with `break_on_diplomacy_panel` and `break_on_war_declaration` true; use save likely to receive diplomacy offer/war declaration.
- **Steps**:
  1. Run auto-turns until diplomacy/war modal appears.
  2. Observe Wingman safety behavior.
- **Pass condition**: No crash; automation pauses; log shows diplomacy/modal breakpoint; player can manually resolve the panel.
- **Evidence**: log line, screenshot of panel or breakpoint, save before/after event.

### S9 — Battle result dismiss regression

- **Setup**: Battle handover or autoresolve-enabled scenario with auto-dismiss battle results true.
- **Steps**:
  1. Complete a battle while Wingman state has pending battle.
  2. Let campaign return to result panel.
- **Pass condition**: Result panel is dismissed only when safe or automation pauses with clear reason; no stuck turn-end loop.
- **Evidence**: pre-dismiss and post-dismiss logs, screenshot if panel remains, save after result.

### S10 — Multiplayer guard regression

- **Setup**: Multiplayer campaign or battle with Wingman and MCT enabled.
- **Steps**:
  1. Launch MP context.
  2. Check logs during campaign/battle start.
- **Pass condition**: Log shows multiplayer detected; no automation listeners/actions run; no desync-causing UI/state changes.
- **Evidence**: MP lobby/campaign screenshot, script log showing disabled state.

## Smoke-test Workflow

1. Enable script logging:
   - Create/verify the WH3 `enable_console_logging` marker in the game `data/script` area according to chadvandy docs.
   - Know both common log locations: WH3 binaries folder and `%APPDATA%\The Creative Assembly\Warhammer3\logs`; search for newest `script_log_*.txt`.

2. Edit source:
   - Edit `.lua` and `.tsv` files in the repo/MyMod source folder.
   - Do not edit generated `.pack` contents as the source of truth.

3. RPFM import:
   - Open/create `!wingman.pack` as PFH5 mod pack.
   - Import folders from repo root: `script/`, `text/`.
   - Convert/import localization source into `text/db/*.loc`.
   - Validate pack structure matches manifest.

4. Install locally:
   - Use RPFM install/copy to the TWW3 `data` folder.
   - Place matching `!wingman.png` thumbnail beside `!wingman.pack`.

5. Launch:
   - Use the original Total War launcher.
   - In Mod Manager, enable MCT first and Wingman.
   - Do not use the new EA Mod Manager for upload testing.

6. Campaign smoke:
   - Start new Immortal Empires campaign.
   - Confirm log contains `[Wingman] init ok`.
   - Open MCT and confirm Wingman settings panel.

7. Scenario smoke:
   - Run S1, S3, S6 first.
   - Then run S2/S9.
   - Then run S8 and S10 last because they are slower/harder to provoke.

8. Evidence capture:
   - Archive `script_log_*.txt`.
   - Save screenshots with scenario IDs.
   - Keep named savegames: `wingman_s1_pre`, `wingman_s1_post`, etc.

## Workshop Publishing Checklist

Required artifacts:
- `!wingman.pack` PFH5 mod pack.
- `!wingman.png` thumbnail, PNG, 256×256, under 1 MB, filename matching pack base.
- `README.md` with feature summary, required MCT dependency, MP disabled note, safety caveats.
- `CHANGELOG.md` with release notes.
- Workshop description copied from README summary.
- MCT required item: Workshop ID `2927955021`.
- Tags: `Campaign`, `UI`.
- Screenshots: MCT settings panel, campaign breakpoint, battle handover.
- Known limitations section: no true human/AI ownership flip, campaign handover is scripted auto-turn orchestration.

Upload steps:
1. Install local `!wingman.pack` and `!wingman.png` in WH3 `data`.
2. Launch original Total War launcher.
3. Open Mod Manager.
4. Right-click Wingman mod.
5. Choose Upload.
6. Accept EULA/mod terms if prompted.
7. Add title, description, tags, thumbnail, dependency on MCT.
8. Publish as hidden/unlisted first for smoke verification.
9. Subscribe from Workshop on a clean profile and run S7.
10. Switch public only after S7 passes.

Update steps:
1. Keep exact same pack filename.
2. Update `CHANGELOG.md`.
3. Rebuild/install pack.
4. Original launcher → Mod Manager → right-click → Update.
5. Add change notes matching changelog entry.

## Risk Register

| Risk | Impact | Mitigation | Baked into file |
|---|---|---|---|
| Diplomacy popup / war declaration race crashes during auto-turn | Crash or stuck turn | Conservative breakpoint on diplomacy/modal panels; no blind auto-clicks unless safe; `pcall` around UI actions. | `wingman_safety.lua`, `wingman_campaign.lua` |
| Save corruption or runaway auto-turn after reload | Lost campaign control | Versioned state keys, last-processed-turn guard, safe-mode on invalid state, duplicate listener removal. | `wingman_state.lua`, `wingman_init.lua` |
| MP desync | Multiplayer desync/crash | `cm:is_multiplayer()` guard at every campaign entry; battle environment no-op when MP detected/unknown. | `wingman_safety.lua`, all runtime files |
| Battle API/context mismatch after patches | Battle handover fails or crashes | `pcall` around alliance/bm calls; scripted AI mode default, instant autoresolve opt-in; log fallback to manual. | `wingman_battle.lua`, `wingman_battle_init.lua` |
| MCT missing or API changes | Settings unavailable or load failure | Required dependency message, default settings fallback, `is_mod_loaded`/function-presence checks, no custom UI fallback in v0.1. | `wingman_mct.lua`, `wingman_init.lua` |

## Open Questions for User

1. Should Wingman’s UI tone be playful/co-pilot themed or strictly functional?
2. Should any faction restrictions ship as presets, or should v0.1 keep all bans empty by default?
3. On turn cap, should “declare victory” be offered in v0.1 or hidden until the rule engine is proven?
4. Should battle handover default to scripted AI mode when enabled, or should it prompt/manual-break before every battle?

## Commit Strategy

Do not commit unless explicitly requested.

Recommended atomic commits when requested:
1. `docs: add Wingman implementation plan`
2. `chore: add mod scaffold and Lua tooling`
3. `feat: add state persistence and safety guards`
4. `feat: add MCT settings and localization`
5. `feat: add campaign handover driver`
6. `feat: add rules and mission objectives`
7. `feat: add battle handover`
8. `test: add manual verification scenarios`
9. `docs: add Workshop packaging checklist`
10. `chore: prepare alpha release assets`

Each commit should include only related files and should pass available static checks plus relevant scenario smoke checks.

## Success Criteria

- `.omo/plans/wingman-mod.md` exists with this plan.
- Pack source mirrors the required structure and imports cleanly into RPFM.
- MCT panel exposes every schema key with localized labels/tooltips.
- No implementation attempts `cm:set_faction_human`.
- MP contexts no-op safely.
- S1–S10 have binary pass/fail evidence.
- Local pack loads in a fresh IE campaign with MCT enabled.
- Workshop checklist is complete before any public upload.

## TODO List (ADD THESE)

> CALLER: Add these TODOs using TodoWrite/TaskCreate and execute by wave.

### Wave 1 (Start Immediately - No Dependencies)

- [ ] **1. Repo scaffold and tooling**
  - What: Create `.gitignore`, Lua tooling configs, docs placeholders, source directories, asset directory, and manual test directory.
  - Depends: None
  - Blocks: 2, 3, 8, 9
  - Category: `quick`
  - Skills: `[]`
  - QA: Verify expected directories/files exist and `.gitignore` does not exclude source files.

- [ ] **2. MCT schema and localization**
  - What: Create MCT settings file and localization source for every schema key.
  - Depends: 1
  - Blocks: 4, 5, 6, 7
  - Category: `unspecified-high`
  - Skills: `[]`
  - QA: In-game MCT panel shows Wingman settings; missing MCT logs dependency error and disables actions.

- [ ] **3. State and safety foundation**
  - What: Implement state machine, versioned persistence, MP guard, safe-call wrapper, popup safety helpers.
  - Depends: 1
  - Blocks: 4, 5, 6, 7
  - Category: `unspecified-high`
  - Skills: [`debugging`]
  - QA: New campaign logs init defaults; MP campaign logs disabled; invalid state enters safe mode.

### Wave 2 (After Wave 1 Completes)

- [ ] **4. Campaign handover driver**
  - What: Implement `FactionTurnStart` auto-turn orchestration, periodic breakpoints, release-to-player flow.
  - Depends: 2, 3
  - Blocks: 7, 8, 10
  - Category: `unspecified-high`
  - Skills: [`debugging`]
  - QA: S1 passes with log evidence and no manual input after first enable.

- [ ] **5. Rules and missions**
  - What: Implement turn cap, custom win evaluators, faction restriction checks, mission-manager builders.
  - Depends: 2, 3
  - Blocks: 7, 8, 10
  - Category: `unspecified-high`
  - Skills: [`debugging`]
  - QA: S3, S4, and S5 pass with log evidence and safe breakpoint/victory behavior.

- [ ] **6. Battle handover**
  - What: Implement campaign battle queue/result handling and battle-mode scripted AI / instant autoresolve behavior.
  - Depends: 2, 3
  - Blocks: 7, 8, 10
  - Category: `unspecified-high`
  - Skills: [`debugging`]
  - QA: S2 and S9 pass with battle log evidence; instant autoresolve remains opt-in.

### Wave 3 (After Wave 2 Completes)

- [ ] **7. Bootstrap integration**
  - What: Wire modules through first-tick init, listener registration/removal, settings refresh, mission initialization, shutdown.
  - Depends: 4, 5, 6
  - Blocks: 8, 9, 10
  - Category: `unspecified-high`
  - Skills: [`debugging`]
  - QA: Fresh campaign logs one init sequence; save reload does not duplicate listeners.

- [ ] **8. TDD verification suite**
  - What: Create `tests/manual/wingman_scenarios.md` with S1–S10 setup, steps, pass condition, and evidence paths.
  - Depends: 4, 5, 6, 7
  - Blocks: 10
  - Category: `writing`
  - Skills: [`debugging`]
  - QA: Every scenario has binary pass condition and required evidence artifact list.

### Wave 4 (After Wave 3 Completes)

- [ ] **9. Packaging and Workshop docs/assets**
  - What: Create README, CHANGELOG, WORKSHOP checklist, thumbnail asset, and RPFM/local install instructions.
  - Depends: 7
  - Blocks: 10
  - Category: `writing`
  - Skills: `[]`
  - QA: `!wingman.png` is 256×256 and <1 MB; docs include MCT dependency and original launcher upload path.

- [ ] **10. Final QA and review**
  - What: Run static checks if available, build/import/install pack via RPFM, run smoke workflow, execute S1–S10, review locked architecture compliance.
  - Depends: 8, 9
  - Blocks: None
  - Category: `unspecified-high`
  - Skills: [`review-work`, `debugging`]
  - QA: All scenarios pass or have blocking bug entries with logs; final review confirms no forbidden API/architecture drift.

## Execution Instructions

1. **Wave 1**: Fire these tasks in parallel where tooling allows.
   ```
   task(category="quick", load_skills=[], run_in_background=false, prompt="Task 1: Create repo scaffold and tooling exactly as specified in .omo/plans/wingman-mod.md. Do not implement runtime features.")
   task(category="unspecified-high", load_skills=[], run_in_background=false, prompt="Task 2: Implement MCT schema and localization exactly as specified in .omo/plans/wingman-mod.md.")
   task(category="unspecified-high", load_skills=["debugging"], run_in_background=false, prompt="Task 3: Implement state and safety foundation exactly as specified in .omo/plans/wingman-mod.md.")
   ```

2. **Wave 2**: After Wave 1 completes, fire feature tasks in parallel.
   ```
   task(category="unspecified-high", load_skills=["debugging"], run_in_background=false, prompt="Task 4: Implement campaign handover driver exactly as specified in .omo/plans/wingman-mod.md.")
   task(category="unspecified-high", load_skills=["debugging"], run_in_background=false, prompt="Task 5: Implement rules and missions exactly as specified in .omo/plans/wingman-mod.md.")
   task(category="unspecified-high", load_skills=["debugging"], run_in_background=false, prompt="Task 6: Implement battle handover exactly as specified in .omo/plans/wingman-mod.md.")
   ```

3. **Wave 3**: Integrate and document verification.
   ```
   task(category="unspecified-high", load_skills=["debugging"], run_in_background=false, prompt="Task 7: Integrate Wingman bootstrap/listeners/settings flow exactly as specified in .omo/plans/wingman-mod.md.")
   task(category="writing", load_skills=["debugging"], run_in_background=false, prompt="Task 8: Create the manual TDD verification suite exactly as specified in .omo/plans/wingman-mod.md.")
   ```

4. **Wave 4**: Prepare release docs/assets and final QA.
   ```
   task(category="writing", load_skills=[], run_in_background=false, prompt="Task 9: Create packaging and Workshop docs/assets exactly as specified in .omo/plans/wingman-mod.md.")
   task(category="unspecified-high", load_skills=["review-work", "debugging"], run_in_background=false, prompt="Task 10: Run final QA/review exactly as specified in .omo/plans/wingman-mod.md.")
   ```

5. Final QA:
   - Run available static Lua checks.
   - Import/install with RPFM.
   - Launch via original launcher.
   - Run S1–S10 and capture evidence.
   - Do not publish publicly until S7 passes from a clean Workshop-style install.
