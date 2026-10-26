import Foundation

// MARK: - Tool Definitions (Canonical)

extension AIChatViewModel {

    /// [T-ios-vision-branch-mismatch #182] THE single source of truth for
    /// "can the model that will actually receive this turn see images itself".
    ///
    /// Both the `read_image` registration (which picks the tool DESCRIPTION) and
    /// its handler (which picks pixels-vs-Vision-Group) must agree, or the model
    /// is told one thing and handed another. They previously each wrote
    /// `selectedModel.capabilities.supportedModalities.contains(.imageInput)` —
    /// textually identical, yet wrong: `selectedModel` is the @Published UI
    /// property, while the REQUEST is built from `resolveCurrentEntry()` (see
    /// `activeModel` in runAgentLoop). With group routing or a session binding
    /// those are different models, so a text-only model could be registered with
    /// the Vision Group tool description and then served by the native pixel
    /// branch — returning metadata and no description at all.
    ///
    /// Resolve from the same entry the request uses, and fall back to
    /// `selectedModel` only when that resolution fails.
    var activeModelHasNativeVision: Bool {
        let model = resolveCurrentEntry()?.model ?? selectedModel
        return model.capabilities.supportedModalities.contains(.imageInput)
    }

    // MARK: - Tool Definitions (Canonical)

    func makeAgentTools() -> [AgentToolDefinition] {
        // [T-memory-toggle-gates-injection-and-tools-ios] memory_get and
        // memory_write are conditionally registered. When the per-session
        // toggle is off, drop both tool definitions so the LLM never sees
        // them. The system prompt also switches to a "memory disabled"
        // wording (see baseSystemPrompt below) so the model can correctly
        // tell the user to re-enable memory via /memory or Settings.
        let includeMemoryTools = memoryEnabled
        var tools: [AgentToolDefinition] = [
            AgentToolDefinition(
                name: "shell_execute",
                description: "Execute a command in an isolated Linux process (iSH/Alpine Linux). The command runs via /bin/sh -c with stdout and stderr captured separately via pipes. Each invocation spawns a fresh process — there is no shared terminal session. Default timeout is 15 minutes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Install Python data analysis packages', 'List files in home directory'). Use the same language as the user."),
                    "command": AgentToolParam(type: .string, description: "The shell command to execute. Supports multi-line commands directly — no special escaping needed. Keep under 1000 chars; for longer scripts, write to a file with file_write first, then run it."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds (default: 900). Use a larger value for long-running commands like package installs."),
                    "delay": AgentToolParam(type: .integer, description: "Delay in seconds before execution begins. The tool blocks the agent flow during this wait WITHOUT occupying the iSH shell, so other concurrent tasks can use it. Use this instead of sleep commands to avoid resource contention."),
                ],
                required: ["tool_title", "command"],
                propertyOrdering: ["tool_title", "command", "timeout", "delay"]
            ),
            AgentToolDefinition(
                name: "file_read",
                description: "Read a file from the Linux filesystem. Faster than shell_execute for reading files — no shell overhead. Returns file content with metadata. Rejects binary files.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Read Python script contents', 'Check system configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to read (e.g. /var/minis/workspace/data.csv)"),
                    "offset": AgentToolParam(type: .integer, description: "1-based line number to start reading from (default: 1). Ignored when direction is 'tail'. If a previous read was truncated, its header ends with next_offset=N — pass that as offset to continue from where it stopped."),
                    "lines": AgentToolParam(type: .integer, description: "Maximum number of lines to return (default: all lines up to max_length)"),
                    "max_length": AgentToolParam(type: .integer, description: "Maximum character length of returned content (default: 15000)"),
                    "direction": AgentToolParam(type: .string, description: "Read direction: 'head' (from start, default) or 'tail' (from end of file)"),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "offset", "lines", "direction", "max_length"]
            ),
            AgentToolDefinition(
                name: "file_write",
                // [T-file-write-large-content-timeout] GH#223. Every byte of
                // `content` has to be GENERATED by the model as tool-call
                // arguments, streamed over the network, before the write even
                // starts. So a single 50-100KB write is a very long, fragile
                // request — the failures users report as "file_write timed out"
                // are the LLM request dying mid-generation, not the (purely
                // local, instant) filesystem write. Splitting into appends makes
                // each request short, and any part that can be COMPUTED rather
                // than transcribed should be, because generated bytes are the
                // actual cost. Without this guidance the model happily emits one
                // giant argument and the turn dies with no useful diagnostic.
                description: "Write content to a file on the Linux filesystem. Faster than shell_execute for writing files. Creates the file if it doesn't exist. Use append mode to add to existing files.\n\nIMPORTANT for large files (roughly >8KB): do NOT emit it as one call. Every byte of `content` is generated and streamed as tool arguments, so one huge call is slow and frequently dies mid-request. Instead either (a) write the first chunk, then extend it with further calls using append: true, or (b) when the content is repetitive or computable (SVG charts, generated tables, boilerplate), write a short script and run it with shell_execute — generating 2KB of code that emits 100KB beats transcribing 100KB.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Create Python statistics script', 'Write configuration file'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to write (e.g. /root/test.txt)"),
                    "content": AgentToolParam(type: .string, description: "The text content to write to the file. For large content prefer several appending calls over one huge one — see the tool description."),
                    "append": AgentToolParam(type: .boolean, description: "If true, append to existing file instead of overwriting (default: false)"),
                    "create_dirs": AgentToolParam(type: .boolean, description: "If true, create parent directories if they don't exist (default: false)"),
                ],
                required: ["tool_title", "path", "content"],
                propertyOrdering: ["tool_title", "path", "content", "append", "create_dirs"]
            ),
            AgentToolDefinition(
                name: "file_edit",
                description: "Make targeted edits to an existing file using exact string replacement. ALWAYS use file_read first to see the current file contents before editing. Prefer file_edit over file_write when modifying existing files — only the changed part needs to be specified. The old_string must match exactly one location in the file (including whitespace/indentation), unless replace_all is true.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Fix typo in Python script', 'Update config value'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Absolute Linux path to the file to edit (e.g. /root/script.py)"),
                    "old_string": AgentToolParam(type: .string, description: "The exact text to find in the file. Must match precisely including whitespace and indentation. Must be unique in the file unless replace_all is true."),
                    "new_string": AgentToolParam(type: .string, description: "The replacement text. Use empty string to delete old_string."),
                    "replace_all": AgentToolParam(type: .boolean, description: "If true, replace ALL occurrences of old_string (default: false)"),
                ],
                required: ["tool_title", "path", "old_string", "new_string"],
                propertyOrdering: ["tool_title", "path", "old_string", "new_string", "replace_all"]
            ),
            AgentToolDefinition(
                name: "browser_use",
                description: "Control a web browser with up to 3 tabs. Do NOT use this tool for minis-clone:// action URLs (open_terminal, views, settings) — those are app deep links, use Markdown links in chat instead. The browser supports both web URLs and minis-clone:// resource URLs. Use minis-clone:// URLs to preview session files (e.g. navigate to minis-clone://workspace/index.html). Sub-resources (JS, CSS, images, fonts) referenced via minis-clone:// absolute paths or relative paths within HTML pages resolve correctly. Use navigate to open URLs, screenshot to see the page (returns an image), click/type to interact with elements, get_text/get_readable to extract content, scroll to navigate long pages, scroll_and_collect to scroll through infinite-scroll/virtual-rendered pages (like Twitter/X timelines) and accumulate unique content items across scroll positions in a single call, find_elements to discover interactive elements, get_page_info for page metadata, get_backbone to get a structural overview of the page DOM as a simplified tree, fetch to download files/resources using the page's session (returns metadata and a minis-clone:// URL), new_tab to open an additional tab, close_tab to close a tab, and list_tabs to see all open tabs. Use set_viewport with viewport_width + viewport_height to override the viewport for the current session (e.g. before screenshotting a 1920×1080 HTML composition that would otherwise be cropped to the phone viewport); pass reset=true to drop the session override and fall back to the global browser setting. Use get_cookies to retrieve cookies for the current page URL / current site root domain only (including HttpOnly cookies). get_cookies supports optional 'keyword' (filter by cookie name) and 'fuzzy' (true=contains match, false=exact match, default true). It returns only a summary and an offload env file path — raw cookie values are NOT included in the tool response. To reuse cookies in shell commands: `. /var/minis/offloads/env_cookies_xxx.sh && command`. You may define alias variables when needed. Use set_cookies to write cookies into the current page's cookie store via the native cookie store (so even HttpOnly cookies, which JS cannot set, land). Pass a 'cookies' array of objects, each with name + value (required) and optional domain (defaults to the current page host), path (defaults to '/'), secure, http_only, and expires (Unix timestamp in seconds; omit for a session cookie). Use wait_for_dom_stable to wait until the page DOM stops changing (useful after navigation or interactions that trigger async data loading — polls every 0.5s, resolves when mutation rate gradient is stable for 3+ intervals, default timeout 10s). Use tab_id to target a specific tab (defaults to the most recently used tab).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Open Wikipedia homepage', 'Take screenshot of current page'). Use the same language as the user."),
                    "action": AgentToolParam(type: .string, description: "The browser action to perform", enumValues: BrowserAction.allCases.map(\.rawValue)),
                    "url": AgentToolParam(type: .string, description: "URL to navigate to (for navigate action) or resource to download (for fetch action)"),
                    "selector": AgentToolParam(type: .string, description: "CSS selector for targeting elements (click, type, get_text, scroll, hover, find_elements). For scroll: specify a scrollable container to scroll (e.g. 'div.timeline'); if omitted, auto-detects the best scrollable element."),
                    "text": AgentToolParam(type: .string, description: "Text to type (for type action)"),
                    "coordinate_x": AgentToolParam(type: .integer, description: "X coordinate for click (alternative to selector)"),
                    "coordinate_y": AgentToolParam(type: .integer, description: "Y coordinate for click (alternative to selector)"),
                    "direction": AgentToolParam(type: .string, description: "Scroll direction", enumValues: ["up", "down"]),
                    "amount": AgentToolParam(type: .integer, description: "Scroll amount in pixels (default: 500)"),
                    "script": AgentToolParam(type: .string, description: "JavaScript code to execute (for execute_js action). The script runs inside an async function wrapper — `await` and top-level `return` are both supported (e.g. `var r = await fetch(url); return await r.json()`). DOM values may be returned directly — a DOMRect, Date, Error, element or NodeList is converted to plain JSON before it reaches you."),
                    "user_agent": AgentToolParam(type: .string, description: "User agent profile to switch to", enumValues: ["desktop_safari", "mobile_safari"]),
                    "max_depth": AgentToolParam(type: .integer, description: "Maximum tree depth for get_backbone (default: 5)"),
                    "scroll_count": AgentToolParam(type: .integer, description: "Number of scroll steps for scroll_and_collect (default: 10, max: 20). Each step scrolls by 'amount' pixels and waits for new content."),
                    "item_selector": AgentToolParam(type: .string, description: "CSS selector for individual content items in scroll_and_collect (e.g. 'article', '[data-testid=\"tweet\"]'). If omitted, auto-detects repeated elements."),
                    "tab_id": AgentToolParam(type: .integer, description: "Target tab ID (optional, defaults to most recently used tab). Use list_tabs to see available tabs."),
                    "keywords": AgentToolParam(type: .string, description: "Filter cookies by name (for get_cookies). A space-separated string or array of strings. With fuzzy=true (default), ALL keywords must appear in the cookie name (case-insensitive). With fuzzy=false, cookie name must exactly equal any one of the provided keywords (case-insensitive). Omit to return all cookies for the current site."),
                    "fuzzy": AgentToolParam(type: .boolean, description: "Whether keyword matching is fuzzy (contains-all) or exact-any (for get_cookies, default: true)."),
                    "cookies": AgentToolParam(type: .string, description: "For set_cookies: a JSON array of cookie objects to write. Pass it as a JSON array (a JSON-encoded string of the array is also accepted). Each object: {\"name\": str (required), \"value\": str (required), \"domain\": str (optional, defaults to current page host), \"path\": str (optional, defaults to \"/\"), \"secure\": bool (optional), \"http_only\": bool (optional — sets an HttpOnly cookie that JS cannot read/set), \"expires\": int (optional, Unix timestamp in seconds; omit for a session cookie)}. Field-name variants from common cookie exports are accepted: httpOnly (=http_only), expirationDate (=expires), sameSite, and case/camel variants — so you can paste cookies verbatim from browser extensions (EditThisCookie / Cookie-Editor) or Playwright/Puppeteer storage."),
                    "timeout": AgentToolParam(type: .integer, description: "Timeout in seconds for wait_for_dom_stable (default: 10). The action polls every 0.5s and resolves when DOM mutation rate stabilizes."),
                    "viewport_width": AgentToolParam(type: .integer, description: "Viewport width in CSS pixels for set_viewport (e.g. 1920). Required together with viewport_height unless reset=true."),
                    "viewport_height": AgentToolParam(type: .integer, description: "Viewport height in CSS pixels for set_viewport (e.g. 1080). Required together with viewport_width unless reset=true."),
                    "reset": AgentToolParam(type: .boolean, description: "For set_viewport: when true, clear the session-level viewport override and fall back to the global browser setting."),
                    "full_page": AgentToolParam(type: .boolean, description: "For screenshot: capture the entire scrollable page by temporarily resizing the WebView to document.documentElement.scrollHeight. Default false captures viewport only. Capped at 32768px tall; when capped, result text includes 'Truncated: true' and the original height."),
                ],
                required: ["tool_title", "action"],
                propertyOrdering: ["tool_title", "action", "tab_id", "url", "selector", "text", "coordinate_x", "coordinate_y", "direction", "amount", "scroll_count", "item_selector", "script", "user_agent", "max_depth", "keywords", "fuzzy", "cookies", "timeout", "viewport_width", "viewport_height", "reset", "full_page"]
            ),
        ]

        if includeMemoryTools {
            tools.append(AgentToolDefinition(
                name: "memory_write",
                description: "Write a memory entry to today's daily log (YYYY-MM-DD.md). Memories persist across all sessions. Each entry is prepended with a timestamp. Save: user preferences, recurring patterns, key facts, project conventions, reusable knowledge. Avoid saving passwords, API keys, tokens, or secrets unless the user explicitly confirms after being warned. Keep entries concise and general-purpose. GLOBAL.md is read-only (user-maintained via Settings).",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Save user preference for Python', 'Note today's project context'). Use the same language as the user."),
                    "content": AgentToolParam(type: .string, description: "The memory content to write. Use concise Markdown with a short heading (## Topic) and context about what was done/learned."),
                ],
                required: ["tool_title", "content"],
                propertyOrdering: ["tool_title", "content"]
            ))
            tools.append(AgentToolDefinition(
                name: "memory_get",
                description: "Retrieve memories from persistent storage. Supports keyword-based fuzzy search across memory files. Returns matching lines with surrounding context. Use this to recall previous knowledge, user preferences, or past notes.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'Recall user preferences', 'Search past notes'). Use the same language as the user."),
                    "scope": AgentToolParam(type: .string, description: "Memory scope to search: 'daily' for daily logs only, 'all' for daily logs + GLOBAL.md.", enumValues: ["daily", "all"]),
                    "keywords": AgentToolParam(type: .string, description: "Space-separated keywords for fuzzy matching (e.g. 'python preference' or 'API key setup'). All keywords must appear in a line or its surrounding context for a match. Leave empty to return full memory files."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "scope", "keywords"]
            ))
        }

        // [T-ios-vision-group #182] Expose read_image when the model can see
        // images ITSELF, or when a Vision Group is configured to see them on its
        // behalf. Previously a text-only model simply never got this tool, so an
        // image on disk was invisible to it with no recourse. The handler picks
        // the matching branch: native models get pixels, others get the Vision
        // Group's description as text.
        //
        // `isConfigured` is strict (group must resolve AND hold a usable
        // image-capable member), so we never advertise a tool whose non-native
        // path has nothing behind it.
        let nativeVision = activeModelHasNativeVision
        // Evaluate FIRST, not inside the `||` below: short-circuiting on
        // `nativeVision` would skip the call, and this read is also what keeps
        // `isConfiguredCached` — which the off-main T264 placeholder builder
        // relies on — up to date.
        let visionGroupConfigured = VisionGroupResolver.isConfigured
        if nativeVision || visionGroupConfigured {
            // Describe what this model will ACTUALLY receive. Promising "the
            // image is returned directly" to a text-only model would set up a
            // false expectation and invite it to re-call the tool when no pixels
            // arrive; the non-native branch returns a written description instead.
            let readImageDescription = nativeVision
                ? "Read an image file from the Linux filesystem and return it for visual analysis. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, or any visual output. The image is returned directly for your analysis along with metadata (dimensions, file size)."
                : "Read an image file from the Linux filesystem and return a written description of it. Supports PNG, JPEG, GIF, WEBP, and other common image formats. Use this to inspect generated charts, downloaded images, screenshots, user-attached photos, or any visual output. You cannot see images directly, so the image is analyzed by a separate vision model and you receive its detailed description plus a transcription of any visible text, along with metadata (dimensions, file size). Because you cannot look again yourself, use the optional 'prompt' argument to ask for exactly what you need from the image — that is your only way to follow up on specific details."
            // [T-ios-vision-group-t264 #182] The `prompt` argument is what makes
            // the non-native branch usable for anything but a generic caption:
            // the host model can't look at the image, so this is its only lever
            // for directing the describing model. On the native branch the model
            // sees the pixels itself, so the argument is documented as optional
            // context rather than a question.
            let promptDescription = nativeVision
                ? "Optional. A note about what you are looking for in the image. Recorded alongside the result; the image itself is returned to you in full either way."
                : "Optional. A specific question or instruction about the image, e.g. 'transcribe the table', 'what error message is shown in this screenshot', 'describe the people and their expressions'. This is passed to the vision model that reads the image for you, so ask for exactly the detail you need. If omitted, a generic detailed description with full text transcription is returned."
            tools.append(AgentToolDefinition(
                name: "read_image",
                description: readImageDescription,
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what this tool call does, shown to the user (e.g. 'View generated bar chart', 'Inspect downloaded screenshot'). Use the same language as the user."),
                    "path": AgentToolParam(type: .string, description: "Linux path (e.g. /var/minis/attachments/chart.png) or minis-clone:// URL (e.g. minis-clone://attachments/chart.png)"),
                    "prompt": AgentToolParam(type: .string, description: promptDescription),
                ],
                required: ["tool_title", "path"],
                propertyOrdering: ["tool_title", "path", "prompt"]
            ))
        }

        // [s2-askuser] 让 AI 中途停下来问她问题再继续：一次最多 4 道题，单选/多选；
        // 界面自动给每题补"其他（自填）/跳过"，AI 不用自己加。答案以 JSON 回 AI，
        // 跳过的题是 null。只在用户正聊着的时候用，别拿它问你自己能定的事。
        tools.append(AgentToolDefinition(
            name: "ask_user_input_v0",
            description: "Ask the user questions and wait for their answers before continuing. Use this when you need the user to make a choice or provide information only they know (e.g. which option to pick, a missing detail, confirmation of an ambiguous request). At most 4 questions per call — keep it to the minimum you truly need. Each question has an id, the question text, a type ('single' for single-choice, 'multi' for multiple-choice), and a list of candidate options. The UI automatically adds 'Other (type your own)' and 'Skip' to every question — do NOT include them in options yourself. Answers come back as JSON mapping question id to the chosen option string, an array of option strings for multi-choice, a custom string for 'Other', or null when skipped. A skipped question means the user didn't answer — proceed with your best judgment for those. Only call this when the user is actively in the conversation; never use it to ask something you could reasonably decide yourself.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what you're asking about, shown to the user (e.g. 'Confirm deployment target'). Use the same language as the user."),
                "questions": AgentToolParam(type: .string, description: "JSON array of question objects, at most 4. Each object: {\"id\": \"q1\", \"question\": \"...\", \"type\": \"single\"|\"multi\", \"options\": [\"option A\", \"option B\"]}. Keep options short (a few words each). The UI adds 'Other' and 'Skip' automatically."),
            ],
            required: ["tool_title", "questions"],
            propertyOrdering: ["tool_title", "questions"]
        ))

        // [s2-search] 第 18 条联网搜索：AI 查资料的成品工具。只在当前选中
        // 的服务商配好 key 后才挂出来（没配好就不让模型看见，避免它空调）。
        if WebSearchService.isConfigured(WebSearchService.selectedProviderId) {
            tools.append(AgentToolDefinition(
                name: "web_search",
                description: "Search the web for current or external information you don't know (news, prices, documentation, facts after your knowledge cutoff, anything that needs checking online). Use this instead of guessing. Results come back as numbered sources [1]..[N] with title, URL and snippet. IMPORTANT: when your reply uses a fact from a result, cite it inline as [cite:<id>] (e.g. [cite:2]) right after the claim. Only use ids from the tool's output — never invent one. Prefer the freshest sources for time-sensitive questions.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary of what you're searching for, shown to the user (e.g. 'Search latest iPhone price'). Use the same language as the user."),
                    "query": AgentToolParam(type: .string, description: "The search query. Write it the way you'd type it into a search engine; English queries often get better coverage for technical topics."),
                    "count": AgentToolParam(type: .integer, description: "How many results to return, 1-20 (default 8). Ask for more only when you need broad coverage."),
                ],
                required: ["tool_title", "query"],
                propertyOrdering: ["tool_title", "query", "count"]
            ))
        }

        // [voice-bubble-tool 2026-10-02] 醒醒：「AI 发语音没有语音气泡」——此前 AI 想发语音
        // 只能去 iSH 沙箱里手搓命令合成音频，没有正规链路。send_voice 复用朗读同款 TTS
        // 链路（AIVoiceMessageComposer：service → group），合成后以微信式语音气泡
        // 落进当前回复并自动播放。模型侧：想发语音就调这个——用户要"发条语音"时，
        // 或你自己觉得用声音说更合适时（像人一样），别自己跑命令。
        tools.append(AgentToolDefinition(
            name: "send_voice",
            description: "Send a voice message to the user. Synthesizes the given text with the configured TTS voice and delivers it as a WeChat-style voice bubble in the chat (it auto-plays for the user). Use this whenever a voice message fits — when the user asks for voice, OR when you decide a voice message fits the moment better than text, like a person choosing to send a voice message instead of typing (a goodnight, affection, comfort, a surprise — your call). Do NOT synthesize audio yourself with shell commands. Write `text` as natural spoken language in the user's language; it will be read aloud as-is. Returns the bubble duration on success.",
            parameters: [
                // [tts-optional-title 2026-10-09] tool_title 改为可选：不传则
                // 按 text 开头自动生成展示摘要，不再强制要求（Kelivo 的
                // textToSpeech 只收文本；title 对语音消息没有功能价值）。
                "tool_title": AgentToolParam(type: .string, description: "Optional: a concise 5-10 word summary of what you're sending, shown to the user (e.g. 'Send goodnight voice message'). Omit it and a summary is generated from the start of `text`. Use the same language as the user."),
                "text": AgentToolParam(type: .string, description: "The words to speak, in the user's language. Keep it conversational and reasonably short — this is what the user will hear."),
                // [voice-bubble-tool 2026-10-02] 点名音色/分组（TTS 施工员转交）。
                // voice = TTS 服务名（服务自带音色配置）；group = TTS 分组名（按成员顺序 fallback）。
                // 名字在 TTS 能力纸条里列着，别自己编。都不传 = 默认 TTS 分组。
                // [B09-S03 2026-10-22] The paper that lists the names is only
                // injected when the user's message matches a voice keyword — so
                // "见纸条里列的" pointed at something that might not be in the
                // prompt at all. Tell the model what to do in that case instead.
                "voice": AgentToolParam(type: .string, description: "可选：点名用哪个 TTS 服务的声音（服务名，原样照抄 TTS 能力纸条里列出的名字）。不传就用默认顺序。如果纸条不在上下文里，说明当前配置还没被列出——这时不要编名字，直接不传这个参数。"),
                "group": AgentToolParam(type: .string, description: "可选：点名用哪个 TTS 分组（分组名，原样照抄纸条里列出的名字），按分组成员顺序自动 fallback。不传就用默认分组。voice 和 group 同时传时以 group 为准。纸条不在上下文里时不要猜名字，直接不传。"),
            ],
            required: ["text"],
            propertyOrdering: ["tool_title", "text", "voice", "group"]
        ))

        // [mcp-agg] MCP 聚合点管理工具：小管家（MCP 小助手人设）给她接入/管理 MCP 用。
        // add_mcp/remove_mcp 两段式（先探、请她确认再落盘）；skill 白名单门控在人设层。
        tools.append(contentsOf: MCPManagementTools.dialogDefinitions())

        // [BUG-09] subagent_task 子代理调度工具
        // [T-sub-agents-v1] Actions wired in this build: delegate (default,
        // with optional wait), status, steer, cancel, resume. The runtime
        // answers each of them — the old "declared but not dispatched"
        // half-state is gone.
        tools.append(AgentToolDefinition(
            name: "subagent_task",
            description: "Delegate a self-contained task to a sub agent — its own isolated context and tool loop, in a hidden child session running concurrently with you — and inspect, steer, stop or restart the ones you started. action defaults to 'delegate'. Available actions: delegate, status, steer, cancel, resume.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise 5-10 word summary shown to the user on the block in the tool bar."),
                "action": AgentToolParam(type: .string, description: "The subagent action to perform: delegate (default), status, steer, cancel or resume."),
                "task": AgentToolParam(type: .string, description: "action=delegate only, required. The complete, self-contained brief: goal, constraints, and return format."),
                // [T-sub-agents-v1] enumValues are the enabled sub agent names,
                // rebuilt every turn (the schema is not cached), so a rename takes
                // effect on the next request and the model cannot invent a name.
                "agent": AgentToolParam(type: .string, description: "action=delegate only. Which sub agent runs this task. Pick the one whose description matches the work; omit it to use the general one.", enumValues: SubAgentStore.shared.subAgents.map(\.name)),
                "wait": AgentToolParam(type: .boolean, description: "action=delegate only. false (default) returns at once with status=running; true blocks until done."),
                "job_id": AgentToolParam(type: .string, description: "action=status/steer/cancel/resume. The job_id returned when the task started. status may omit it to list every delegation of this conversation."),
                "message": AgentToolParam(type: .string, description: "action=steer only, required. The correction instruction to the running sub agent.")
            ],
            required: ["tool_title"],
            propertyOrdering: ["tool_title", "action", "task", "agent", "wait", "job_id", "message"]
        ))

        // [Kelivo 本地工具 13 项真定义落地]
        // 1. timeInfo (时间信息)
        tools.append(AgentToolDefinition(
            name: "timeInfo",
            description: "Read current device date, day of the week, time, timezone, UTC offset, and timestamp.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI.")
            ],
            required: [],
            propertyOrdering: ["tool_title"]
        ))

        // 2. clipboard (剪切板)
        tools.append(AgentToolDefinition(
            name: "clipboard",
            description: "Read or write plain text on the device clipboard.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "action": AgentToolParam(type: .string, description: "The clipboard action: 'read' to get clipboard text, or 'write' to set it."),
                "text": AgentToolParam(type: .string, description: "The text to copy when action is 'write'.")
            ],
            required: ["action"],
            propertyOrdering: ["tool_title", "action", "text"]
        ))

        // 3. textToSpeech (send_voice 的旧别名 —— 裁定：两个名字都保留、共享同一实现)
        tools.append(AgentToolDefinition(
            name: "textToSpeech",
            description: "Alias of send_voice — synthesizes the given text with the configured TTS voice and delivers it as a WeChat-style voice bubble in the chat (auto-plays). Same behavior and the same AI Voice Replies switch as send_voice; prefer send_voice for new calls. Do NOT synthesize audio yourself with shell commands.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "text": AgentToolParam(type: .string, description: "The words to speak aloud.")
            ],
            required: ["text"],
            propertyOrdering: ["tool_title", "text"]
        ))

        // 4. askUser (询问用户别名定义)
        tools.append(AgentToolDefinition(
            name: "askUser",
            description: "Ask the user questions and wait for their answers before continuing.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "A concise summary of what you're asking about."),
                "questions": AgentToolParam(type: .string, description: "JSON array of question objects, at most 4.")
            ],
            required: ["tool_title", "questions"],
            propertyOrdering: ["tool_title", "questions"]
        ))

        // 5. calculate (计算器)
        tools.append(AgentToolDefinition(
            name: "calculate",
            description: "Calculate mathematical expressions accurately (supports +, -, *, /, powers, sqrt, sin, cos, abs, etc.).",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "expression": AgentToolParam(type: .string, description: "The mathematical expression to evaluate, e.g. 'sqrt(144) + 12 * 3'.")
            ],
            required: ["expression"],
            propertyOrdering: ["tool_title", "expression"]
        ))

        // 6. calendarQuery (查询日历)
        tools.append(AgentToolDefinition(
            name: "calendarQuery",
            description: "Query calendar events on this device within an optional date range or keyword query.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "query": AgentToolParam(type: .string, description: "Optional keyword search query."),
                "start_date": AgentToolParam(type: .string, description: "Optional start date filter, ISO 8601 (e.g. '2026-10-12')."),
                "end_date": AgentToolParam(type: .string, description: "Optional end date filter (e.g. '2026-10-13').")
            ],
            required: [],
            propertyOrdering: ["tool_title", "query", "start_date", "end_date"]
        ))

        // 7. calendarCreate (创建日程)
        tools.append(AgentToolDefinition(
            name: "calendarCreate",
            description: "Create a calendar event on this device.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "title": AgentToolParam(type: .string, description: "Title of the calendar event."),
                "start_time": AgentToolParam(type: .string, description: "Start time, ISO 8601 (e.g. '2026-10-12T18:00:00'). A space instead of T is tolerated."),
                "end_time": AgentToolParam(type: .string, description: "End time, ISO 8601 (e.g. '2026-10-12T19:00:00'). A space instead of T is tolerated."),
                "notes": AgentToolParam(type: .string, description: "Optional notes or description.")
            ],
            required: ["title", "start_time", "end_time"],
            propertyOrdering: ["tool_title", "title", "start_time", "end_time", "notes"]
        ))

        // 8. currentLocation (当前位置)
        tools.append(AgentToolDefinition(
            name: "currentLocation",
            description: "Get current device location coordinates, city, and address.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI.")
            ],
            required: [],
            propertyOrdering: ["tool_title"]
        ))

        // 9. weather (天气)
        tools.append(AgentToolDefinition(
            name: "weather",
            description: "Get current weather conditions and forecast for current or specified location via Apple WeatherKit.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "location": AgentToolParam(type: .string, description: "Optional location name or city (defaults to current location).")
            ],
            required: [],
            propertyOrdering: ["tool_title", "location"]
        ))

        // 10. remindersQuery (查询提醒)
        tools.append(AgentToolDefinition(
            name: "remindersQuery",
            description: "Query reminders on this device.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "list_name": AgentToolParam(type: .string, description: "Optional reminder list name filter."),
                "show_completed": AgentToolParam(type: .boolean, description: "Whether to include completed reminders (default false).")
            ],
            required: [],
            propertyOrdering: ["tool_title", "list_name", "show_completed"]
        ))

        // 11. remindersCreate (创建提醒)
        tools.append(AgentToolDefinition(
            name: "remindersCreate",
            description: "Create a reminder on this device.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "title": AgentToolParam(type: .string, description: "Title of the reminder."),
                "due_date": AgentToolParam(type: .string, description: "Optional due date, ISO 8601 (e.g. '2026-10-12T20:00:00')."),
                "notes": AgentToolParam(type: .string, description: "Optional reminder notes."),
                "list_name": AgentToolParam(type: .string, description: "Optional list name to add to.")
            ],
            required: ["title"],
            propertyOrdering: ["tool_title", "title", "due_date", "notes", "list_name"]
        ))

        // 12. remindersComplete (完成提醒)
        tools.append(AgentToolDefinition(
            name: "remindersComplete",
            description: "Mark a reminder as completed on this device.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "title": AgentToolParam(type: .string, description: "Title of the reminder to mark complete."),
                "reminder_id": AgentToolParam(type: .string, description: "Optional unique ID of the reminder.")
            ],
            required: [],
            propertyOrdering: ["tool_title", "title", "reminder_id"]
        ))

        // 13. healthSummary (健康摘要)
        tools.append(AgentToolDefinition(
            name: "healthSummary",
            description: "Read health and activity summary on this device (step count, active energy burned, walking/running distance, sleep analysis).",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Optional summary shown in UI."),
                "days": AgentToolParam(type: .integer, description: "Number of days of health data to query (default 1).")
            ],
            required: [],
            propertyOrdering: ["tool_title", "days"]
        ))

        // [Kelivo Alignment & BUG-01 / BUG-03] 人设本地工具白名单真实门控
        let pid = sessionPersonaId ?? PersonaStore.currentID()
        if let p = PersonaStore.shared.personas.first(where: { $0.id == pid }),
           let toolWhitelist = p.localToolIds {
            if !toolWhitelist.contains("timeInfo") {
                tools.removeAll { $0.name == "timeInfo" || $0.name == "get_time_info" }
            }
            if !toolWhitelist.contains("clipboard") {
                tools.removeAll { $0.name == "clipboard" || $0.name == "clipboard_tool" }
            }
            if !toolWhitelist.contains("textToSpeech") {
                // [AUD8-02] One whitelist id governs the alias pair — they
                // share one implementation, so they share one gate.
                tools.removeAll { $0.name == "textToSpeech" || $0.name == "text_to_speech" || $0.name == "send_voice" }
            }
            if !toolWhitelist.contains("askUser") {
                tools.removeAll { $0.name == "askUser" || $0.name == "ask_user_input_v0" || $0.name == "user_ask" }
            }
            if !toolWhitelist.contains("calculate") {
                tools.removeAll { $0.name == "calculate" }
            }
            if !toolWhitelist.contains("calendarQuery") {
                tools.removeAll { $0.name == "calendarQuery" }
            }
            if !toolWhitelist.contains("calendarCreate") {
                tools.removeAll { $0.name == "calendarCreate" }
            }
            if !toolWhitelist.contains("currentLocation") {
                tools.removeAll { $0.name == "currentLocation" }
            }
            if !toolWhitelist.contains("weather") {
                tools.removeAll { $0.name == "weather" }
            }
            if !toolWhitelist.contains("remindersQuery") {
                tools.removeAll { $0.name == "remindersQuery" }
            }
            if !toolWhitelist.contains("remindersCreate") {
                tools.removeAll { $0.name == "remindersCreate" }
            }
            if !toolWhitelist.contains("remindersComplete") {
                tools.removeAll { $0.name == "remindersComplete" }
            }
            if !toolWhitelist.contains("healthSummary") {
                tools.removeAll { $0.name == "healthSummary" }
            }
        }

        // 表情包抽屉浏览工具：支持模型翻看特定抽屉的完整表情包目录
        tools.append(AgentToolDefinition(
            name: "browse_stickers",
            description: "Browse the full sticker catalog of a specific drawer/category (e.g. 委屈, 撒娇, 开心, 嘲讽, 难过) to pick a suitable sticker.",
            parameters: [
                "drawer": AgentToolParam(type: .string, description: "The name of the drawer/category to browse (e.g. 委屈, 撒娇, 开心, 嘲讽).")
            ],
            required: ["drawer"],
            propertyOrdering: ["drawer"]
        ))

        // [batch1] Global tool switches (AgentToolSwitch): OFF means removed,
        // not refused — the model never sees a switched-off tool in the schema.
        // Applied last so it covers every append path (incl. persona-whitelist
        // survivors above).
        tools.removeAll { !AgentToolSwitch.isToolEnabled($0.name) }

        return tools
    }

}

// MARK: - Capabilities Catalog & Vector Router Hook (Progressive Disclosure)

/// Categorized capability in the progressive disclosure directory.
public struct CatalogItem: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let category: CatalogCategory
    public let synopsis: String      // Concise trigger condition & purpose
    public let quickSyntax: String    // Fast usage example
    public let docRef: String        // Where to query full documentation

    public init(id: String, name: String, category: CatalogCategory, synopsis: String, quickSyntax: String, docRef: String) {
        self.id = id
        self.name = name
        self.category = category
        self.synopsis = synopsis
        self.quickSyntax = quickSyntax
        self.docRef = docRef
    }
}

public enum CatalogCategory: String, CaseIterable, Sendable {
    case system = "System & Shell"
    case apple = "Apple Native Frameworks"
    case webMedia = "Web & Communication"
    case memoryExtensions = "Memory & Extensions"
}

/// [T-vector-router-hook] Extension point for dedicated embedding / vector router model.
/// When configured, the router dynamically selects relevant tools based on user prompt.
public protocol VectorCatalogRouterProtocol: AnyObject, Sendable {
    func route(query: String, availableItems: [CatalogItem]) async throws -> [CatalogItem]
}

public final class ToolCatalogRouter: @unchecked Sendable {
    public static let shared = ToolCatalogRouter()

    /// Plug-and-play hook for vector / embedding routing model.
    public var vectorRouter: (any VectorCatalogRouterProtocol)?

    public func defaultCatalogItems() -> [CatalogItem] {
        [
            // System & Shell
            CatalogItem(
                id: "shell_execute",
                name: "shell_execute",
                category: .system,
                synopsis: "Execute commands/scripts in isolated Linux iSH shell (Alpine aarch64).",
                quickSyntax: "tool call: shell_execute(command: \"...\")",
                docRef: "Tool schema (timeout default 900s, delay for polling)"
            ),
            CatalogItem(
                id: "file_ops",
                name: "file_read / file_write / file_edit",
                category: .system,
                synopsis: "Direct Linux filesystem manipulation (faster/atomic).",
                quickSyntax: "tool calls: file_read, file_write (split large content), file_edit",
                docRef: "Tool schemas"
            ),
            CatalogItem(
                id: "minis-config",
                name: "minis-config",
                category: .system,
                synopsis: "Read or change app settings (providers, models, groups, envvars).",
                quickSyntax: "minis-config get <key> | set <key> <val>",
                docRef: "minis-config --help | minis-config topic-help <topic>"
            ),
            CatalogItem(
                id: "minis-scheduled",
                name: "minis-scheduled",
                category: .system,
                synopsis: "Schedule delayed or recurring prompts; prefill shell commands; proactive autonomy pulses.",
                quickSyntax: "minis-scheduled create --prompt \"...\" --after 10m [--command \"<cmd>\" | --pulse]",
                docRef: "minis-scheduled --help (supports --command prefill, --pulse autonomous heartbeat, --target follow-up default in chat)"
            ),
            CatalogItem(
                id: "minis-sessions-cli",
                name: "minis-sessions-cli",
                category: .system,
                synopsis: "Manage and inspect past conversation sessions.",
                quickSyntax: "minis-sessions-cli list | messages --id <sid>",
                docRef: "minis-sessions-cli --help"
            ),
            CatalogItem(
                id: "minis-model-use",
                name: "minis-model-use",
                category: .system,
                synopsis: "Single-shot invocation of pre-configured secondary models.",
                quickSyntax: "minis-model-use run --model <id> --input <json>",
                docRef: "minis-model-use --help"
            ),
            // [B28 C-2 / F-1] `minis-theme` 一直没进能力目录，而这份目录是
            // 唯一告诉模型"你会什么"的清单 —— 用户说"帮我做套粉色主题"，
            // 模型根本想不到有这个能力。技能正文里提过它，但技能注入要过
            // 人设白名单和条数上限，靠不住。
            CatalogItem(
                id: "minis-theme",
                name: "minis-theme",
                category: .system,
                synopsis: "Read or change the app's look: colors per role/scope, bubble shapes, wallpapers, fonts, theme library.",
                quickSyntax: "minis-theme get | apply --file <json> | color --list --scope chat | list | use --id <id>",
                docRef: "minis-theme --help (get/apply/export/reset/undo/avatar/icon/wallpaper/color/save/list/use/rename/delete)"
            ),
            CatalogItem(
                id: "open_terminal",
                name: "Interactive Terminal",
                category: .system,
                synopsis: "Interactive terminal for stdin tasks (passwords, ssh, htop).",
                quickSyntax: "[Open Terminal](minis-clone://open_terminal?init_command=...)",
                docRef: "Markdown link with percent-encoded init_command"
            ),

            // Apple Native Frameworks
            CatalogItem(
                id: "apple-vision",
                name: "apple-vision",
                category: .apple,
                synopsis: "Image analysis (OCR, barcodes, faces, similarity, overlap).",
                quickSyntax: "apple-vision ocr|classify|similarity|overlap <img...>",
                docRef: "apple-vision --help"
            ),
            CatalogItem(
                id: "apple-healthkit",
                name: "apple-healthkit",
                category: .apple,
                synopsis: "Query or record Apple Health data (vitals, sleep, workouts).",
                quickSyntax: "apple-healthkit batch --types <t1,t2> --days N",
                docRef: "apple-healthkit --help | apple-healthkit types"
            ),
            CatalogItem(
                id: "apple-homekit",
                name: "apple-homekit",
                category: .apple,
                synopsis: "Control HomeKit smart home accessories and scenes.",
                quickSyntax: "apple-homekit list | set --name ... --characteristic ... --value ...",
                docRef: "apple-homekit --help"
            ),
            CatalogItem(
                id: "apple-maps",
                name: "apple-maps",
                category: .apple,
                synopsis: "POI search, route navigation, and travel ETA.",
                quickSyntax: "apple-maps search --query <text> --lat <lat> --lon <lon> | route --from ... --to ... | eta --from ... --to ...",
                docRef: "apple-maps --help"
            ),
            CatalogItem(
                id: "apple-player",
                name: "apple-player",
                category: .apple,
                synopsis: "Media playback control for audio and video files.",
                quickSyntax: "apple-player play <file> | pause|resume|status|stop <session_id>",
                docRef: "apple-player --help (play returns a session_id; the rest need it)"
            ),
            CatalogItem(
                id: "apple-alarm",
                name: "apple-alarm",
                category: .apple,
                synopsis: "Manage iOS system alarms and countdown timers.",
                quickSyntax: "apple-alarm list | set --time HH:mm",
                docRef: "apple-alarm --help (view at minis-clone://views/alarm)"
            ),
            CatalogItem(
                id: "apple-open",
                name: "apple-open",
                category: .apple,
                synopsis: "Open system URI schemes via iOS system handler (tel:, maps://, settings:).",
                quickSyntax: "apple-open <url>",
                docRef: "apple-open --help"
            ),
            CatalogItem(
                id: "apple-device",
                name: "apple-device",
                category: .apple,
                synopsis: "Device facts and battery state (model, OS, CPU, disk, network).",
                quickSyntax: "apple-device info | battery",
                docRef: "apple-device --help"
            ),
            CatalogItem(
                id: "apple-clipboard",
                name: "apple-clipboard",
                category: .apple,
                synopsis: "Read, write, or clear the device clipboard.",
                quickSyntax: "apple-clipboard get | set --text \"...\" | clear | status",
                docRef: "apple-clipboard --help (privacy: needs the user's permission)"
            ),
            CatalogItem(
                id: "apple-location",
                name: "apple-location",
                category: .apple,
                synopsis: "Current GPS position, reverse geocode, and forward geocode.",
                quickSyntax: "apple-location current | geocode --lat ... --lng ... | forward --address \"...\"",
                docRef: "apple-location --help (privacy: needs the user's permission)"
            ),
            CatalogItem(
                id: "apple-photos",
                name: "apple-photos",
                category: .apple,
                synopsis: "Photo library: list, albums, stats, export to /var/minis/offloads/.",
                quickSyntax: "apple-photos list --limit N | albums | album --name ... | export --id <asset-id>",
                docRef: "apple-photos --help (privacy: needs the user's permission)"
            ),
            CatalogItem(
                id: "apple-calendar",
                name: "apple-calendar",
                category: .apple,
                synopsis: "Calendar events and reminders (list, create, update, delete).",
                quickSyntax: "apple-calendar list --start <ISO> --end <ISO> | create --title ... --start ... --end ...",
                docRef: "apple-calendar --help (privacy: reads need permission, writes always ask)"
            ),
            CatalogItem(
                id: "apple-reminders",
                name: "apple-reminders",
                category: .apple,
                synopsis: "Reminders: list, lists, create, update, complete, delete.",
                quickSyntax: "apple-reminders list | lists | create --title ... | complete --id <id>",
                docRef: "apple-reminders --help (complete/update/delete need --id, not --title)"
            ),
            CatalogItem(
                id: "apple-weather",
                name: "apple-weather",
                category: .apple,
                synopsis: "WeatherKit forecasts: current, hourly, daily, alerts, report.",
                quickSyntax: "apple-weather current | hourly | daily | report [--lat N --lng N]",
                docRef: "apple-weather --help"
            ),
            CatalogItem(
                id: "apple-media",
                name: "apple-media",
                category: .apple,
                synopsis: "Now-playing info and Music playback transport control.",
                quickSyntax: "apple-media now-playing | play | pause | toggle | next | prev | volume",
                docRef: "apple-media --help"
            ),
            CatalogItem(
                id: "apple-notification",
                name: "apple-notification",
                category: .apple,
                synopsis: "Inspect local notifications (pending, delivered) and auth status.",
                quickSyntax: "apple-notification pending | delivered | settings",
                docRef: "apple-notification --help"
            ),
            CatalogItem(
                id: "apple-bluetooth",
                name: "apple-bluetooth",
                category: .apple,
                synopsis: "BLE scan, connect, and read/write characteristics.",
                quickSyntax: "apple-bluetooth status | scan | connect --uuid ... | read --uuid ... --service ... --characteristic ...",
                docRef: "apple-bluetooth --help (privacy: needs the user's permission)"
            ),
            CatalogItem(
                id: "apple-nfc",
                name: "apple-nfc",
                category: .apple,
                synopsis: "NFC tag reading and NDEF writing (iOS 26+, device dependent).",
                quickSyntax: "apple-nfc status | scan | write --type text --payload \"...\"",
                docRef: "apple-nfc --help"
            ),
            CatalogItem(
                id: "apple-nlp",
                name: "apple-nlp",
                category: .apple,
                synopsis: "On-device NLP: language detection, tokenize, POS, NER, sentiment.",
                quickSyntax: "apple-nlp language --text \"...\" | tokenize | pos | sentiment",
                docRef: "apple-nlp --help"
            ),
            CatalogItem(
                id: "apple-speech",
                name: "apple-speech",
                category: .apple,
                synopsis: "Speech-to-text on an audio file (SFSpeechRecognizer).",
                quickSyntax: "apple-speech transcribe --source mic --duration 5 | transcribe --source <audio-file>",
                docRef: "apple-speech --help"
            ),
            CatalogItem(
                id: "apple-speak",
                name: "apple-speak",
                category: .apple,
                synopsis: "Quick one-off spoken announcements (does not record in chat).",
                quickSyntax: "apple-speak speak --text \"...\" --voice zh-CN",
                docRef: "apple-speak --help"
            ),

            // Web & Communication
            CatalogItem(
                id: "browser_use",
                name: "browser_use",
                category: .webMedia,
                synopsis: "WebKit browser automation (navigate, screenshot, click, type, scroll, cookies).",
                quickSyntax: "tool call: browser_use(action: \"navigate\", url: \"...\")",
                docRef: "Tool schema | minis-browser-use --help"
            ),
            CatalogItem(
                id: "send_voice",
                name: "send_voice / textToSpeech",
                category: .webMedia,
                synopsis: "Send WeChat-style voice message bubbles via configured TTS service.",
                quickSyntax: "tool call: send_voice(text: \"...\")",
                docRef: "Tool schema (voice bubble in chat)"
            ),
            CatalogItem(
                id: "web_search",
                name: "web_search",
                category: .webMedia,
                synopsis: "Search live web information (news, facts, documentation).",
                quickSyntax: "tool call: web_search(query: \"...\")",
                docRef: "Tool schema (cite sources with [cite:id])"
            ),
            CatalogItem(
                id: "minis-open",
                name: "minis-open",
                category: .webMedia,
                synopsis: "In-app preview for web URLs or files in /var/minis/ without leaving chat.",
                quickSyntax: "minis-open <url-or-path>",
                docRef: "minis-open --help"
            ),

            // Memory & Extensions
            CatalogItem(
                id: "memory_tools",
                name: "memory_write / memory_get",
                category: .memoryExtensions,
                synopsis: "Persistent memory logging (YYYY-MM-DD.md) and keyword recall.",
                quickSyntax: "tool calls: memory_write(content: \"...\"), memory_get(keywords: \"...\")",
                docRef: "Tool schema"
            ),
            CatalogItem(
                id: "skills_catalog",
                name: "Skills",
                category: .memoryExtensions,
                synopsis: "Reusable instruction playbooks at /var/minis/skills/<id>/SKILL.md.",
                quickSyntax: "Read /var/minis/skills/<id>/SKILL.md before executing",
                docRef: "List /var/minis/skills/ to discover"
            ),
            CatalogItem(
                id: "subagent_task",
                name: "subagent_task",
                category: .memoryExtensions,
                synopsis: "Delegate a self-contained job to a sub agent with its own tool loop; returns a result message later.",
                quickSyntax: "tool call: subagent_task(task: \"...\", agent: \"...\", wait: true|false)",
                docRef: "Tool schema (status/steer/cancel/resume actions)"
            ),
            CatalogItem(
                id: "ask_user",
                name: "askUser / ask_user_input_v0",
                category: .memoryExtensions,
                synopsis: "Ask the user a question on an in-chat card and wait for the answer (options / confirm / free text).",
                quickSyntax: "tool call: askUser(questions: [{type: \"options\", question: \"...\", options: [...]}])",
                docRef: "Tool schema"
            ),
            CatalogItem(
                id: "device_utility_tools",
                name: "calculate / timeInfo / clipboard / read_image",
                category: .system,
                synopsis: "Built-in device utilities: math evaluation, local date-time, clipboard read/write, image inspection.",
                quickSyntax: "tool calls: calculate(expression), timeInfo, clipboard(action: read|write), read_image(path)",
                docRef: "Tool schemas"
            ),
            CatalogItem(
                id: "device_data_tools",
                name: "weather / currentLocation / calendar* / reminders* / healthSummary",
                category: .apple,
                synopsis: "Structured wrappers over Apple frameworks: weather (location is geocoded to lat/lng first), location, calendar query+create, reminders query+create+complete, health summary.",
                quickSyntax: "tool calls: weather(location), currentLocation, calendarQuery(range), calendarCreate(title,start_time,end_time), remindersQuery(list_name), remindersCreate(title,due_date), remindersComplete(reminder_id), healthSummary",
                docRef: "Tool schemas (the apple-* CLI entries below are the raw equivalents)"
            ),
            CatalogItem(
                id: "browse_stickers",
                name: "browse_stickers",
                category: .webMedia,
                synopsis: "Browse one sticker drawer's full catalog to pick an exact sticker id before sending.",
                quickSyntax: "tool call: browse_stickers(drawer: \"撒娇\")",
                docRef: "Tool schema"
            ),
            CatalogItem(
                id: "mcp_catalog",
                name: "MCP Servers",
                category: .memoryExtensions,
                synopsis: "External MCP server ecosystem for specialized tools.",
                quickSyntax: "minis-mcp-cli tools <server> | call <server> <tool>",
                docRef: "minis-mcp-cli list | minis-mcp-cli --help"
            ),
            CatalogItem(
                id: "mcp_management",
                name: "add_mcp / list_mcp / remove_mcp / toggle_mcp",
                category: .memoryExtensions,
                synopsis: "Add, list, remove or enable/disable an MCP server from chat (two-stage: probe first, then write after the owner confirms).",
                quickSyntax: "tool calls: list_mcp, add_mcp(name, transport, url|command), toggle_mcp(name, enabled), remove_mcp(name)",
                docRef: "Tool schemas"
            )
        ]
    }

    /// Renders the catalog as a compact, structured Markdown index.
    public func renderCatalogFragment(items: [CatalogItem]? = nil) -> String {
        let activeItems = items ?? defaultCatalogItems()
        var out = "## Capabilities & Tools Catalog (Progressive Disclosure Index)\n"
        out += "All tools and CLIs support `--help` for full flags and syntax. Query details only when needed.\n\n"

        for cat in CatalogCategory.allCases {
            let catItems = activeItems.filter { $0.category == cat }
            guard !catItems.isEmpty else { continue }
            out += "### \(cat.rawValue)\n"
            for item in catItems {
                out += "- `\(item.name)`: \(item.synopsis) [Usage: `\(item.quickSyntax)`] (Spec: \(item.docRef))\n"
            }
            out += "\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}


// MARK: - Sub agent roster  [batch7][G5]

extension AIChatViewModel {
    /// The "which sub agent for which job" section of the system prompt.
    ///
    /// [batch7][G5] Built from the same roster the `agent` parameter's
    /// enumValues come from, so a name can never be advertised in one and
    /// rejected by the other. The per-line Model note tells the model where
    /// each agent runs (a pinned group vs Auto), which is information only —
    /// the model does not choose it — but explains why two agents can behave
    /// differently on the same task.
    ///
    /// Cost is bounded by SubAgentLimits (10 × (40 + 200) chars), with a
    /// defensive prefix(200) here in case a definition reached storage through
    /// some path that skipped the clamp.
    @MainActor
    static func subAgentRosterSection() -> String {
        let roster = SubAgentStore.shared.subAgents
        guard !roster.isEmpty else { return "" }
        let store = ProviderConfigStore.shared
        var lines = ["Available sub agents (pass the name as \(SubAgentDefinition.toolName).agent):"]
        for def in roster {
            let desc = String(def.description.prefix(SubAgentLimits.descriptionMaxLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let model: String
            if let gid = def.modelGroupId, let group = store.group(for: gid) {
                // Pinned by the user: every run of this agent uses the group.
                model = "fixed — \(group.name)"
            } else {
                // Auto: the resolver follows this conversation's model.
                model = "Auto — follows this conversation's model"
            }
            lines.append("- \(def.name) — \(desc) Model: \(model).")
        }
        lines.append("Prefer a specific sub agent when its description matches; otherwise use the general one.")
        return lines.joined(separator: "\n") + "\n"
    }
}
