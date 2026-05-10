# Scribe Behavioral Library

This document is the psychological and sociological knowledge base that Scribe internalizes as part of its core observation skill. It is not user-facing. It is the lens through which Scribe observes session behavior when `behavioral_tracking` is enabled.

The full library is always loaded. Scribe observes through all lenses simultaneously but only surfaces what is relevant to the current session. This is not selected per user — every Scribe instance has the complete library internalized.

---

## 1. Cognitive Patterns

How the user processes information, makes decisions, and allocates attention.

---

### 1.1 Decision-Making Biases

#### Confirmation Bias

**What it is.** The tendency to seek, interpret, and remember information that confirms existing beliefs while ignoring contradictory evidence.

**Observable signals.** User dismisses error messages that contradict their hypothesis. User searches for documentation supporting their approach but does not search for alternatives. User ignores failing tests and focuses on passing ones. User says "I knew it" when evidence appears but never says "I was wrong." User asks the AI to validate a decision already made rather than to evaluate options.

**Why it matters.** Reveals whether the user is genuinely investigating or performing confirmation theater. Persistent confirmation bias correlates with recurring bugs and architectural dead ends. Users who overcome this bias show faster debugging and better architectural decisions over time.

#### Anchoring

**What it is.** Over-reliance on the first piece of information encountered when making decisions, even when later information should override it.

**Observable signals.** User fixates on the first solution proposed and evaluates all subsequent options relative to it. User references an initial estimate repeatedly even after new information changes the scope. User returns to an early approach after trying alternatives, not because it was best but because it was first. Error messages from the first attempt frame the entire debugging session.

**Why it matters.** Anchoring constrains the solution space. Users anchored to an early approach often miss better solutions discovered later. Tracking anchoring reveals whether the user's decision-making is adaptive or rigid.

#### Sunk Cost Fallacy

**What it is.** Continuing to invest in a failing approach because of the resources already spent rather than evaluating the current situation objectively.

**Observable signals.** User says "we've already built this" or "I've spent too long on this to switch." User continues debugging an approach for 30+ minutes after identifying a fundamental flaw. User resists refactoring code they spent significant time writing. User escalates commitment to a tool or library after investing setup time, even when it is clearly wrong for the use case.

**Why it matters.** Sunk cost behavior is one of the most expensive patterns in software development. It directly correlates with wasted sessions. Users who learn to cut losses early ship faster and accumulate fewer corrections.

#### Availability Heuristic

**What it is.** Judging the likelihood or importance of something based on how easily examples come to mind rather than on actual frequency or data.

**Observable signals.** User assumes a recent bug type is the cause of a new issue without investigation. User over-indexes on the most dramatic failure from last week when assessing risk. User applies a fix that worked for the last problem without checking whether this problem is the same. User says "this always happens" when it has happened twice.

**Why it matters.** The availability heuristic causes misdiagnosis. Users under its influence skip systematic investigation and jump to pattern-matched conclusions. Tracking this reveals whether the user's debugging is evidence-driven or memory-driven.

#### Optimism Bias

**What it is.** The tendency to overestimate the likelihood of positive outcomes and underestimate risks, costs, and timelines.

**Observable signals.** User estimates a task will take 30 minutes, then spends 3 hours. User says "this should be straightforward" before encountering edge cases. User skips error handling because "this won't fail in practice." User commits without testing because "it's a simple change." User plans 5 features for a session and completes 2.

**Why it matters.** Optimism bias drives under-scoping, insufficient error handling, and skipped testing. It is the root cause of most "simple change broke production" corrections. Tracking the gap between estimated and actual effort reveals calibration improvement over time.

#### Status Quo Bias

**What it is.** Preference for the current state of things, where any change is perceived as a loss even when the change would be an improvement.

**Observable signals.** User resists upgrading dependencies despite known issues. User keeps a suboptimal architecture because "it works." User avoids refactoring even when the current code causes repeated bugs. User chooses workarounds over proper fixes to avoid modifying existing systems.

**Why it matters.** Status quo bias accumulates technical debt. The short-term comfort of no change produces long-term compounding costs. Users who overcome this bias show healthier codebases and fewer recurring corrections over time.

#### Dunning-Kruger Effect

**What it is.** Overestimating competence in areas of low experience and underestimating competence in areas of high experience. Both directions are relevant.

**Observable signals (overestimation).** User skips documentation in a new technology. User makes confident architectural decisions in unfamiliar territory without research. User says "I don't need a tutorial for this" and then hits basic errors. User dismisses AI suggestions in domains where they have limited experience.

**Observable signals (underestimation).** User over-relies on AI for tasks they could handle independently. User asks for confirmation on decisions they have already correctly reasoned through. User hedges language ("I think," "maybe," "not sure") on topics where their track record shows competence.

**Why it matters.** Overestimation leads to corrections that should have been prevented by research. Underestimation leads to unnecessary dependency and slower autonomy growth. Tracking both directions reveals the user's calibration curve across different skill areas.

#### Planning Fallacy

**What it is.** The tendency to underestimate the time, costs, and risks of future actions while overestimating their benefits, even when past experience contradicts the estimate.

**Observable signals.** Repeated pattern of session goals exceeding session output. User scopes multi-session features as single-session tasks. User does not reference past session durations when estimating new work. User starts new features late in a session with insufficient time to complete them.

**Why it matters.** The planning fallacy directly causes incomplete features, rushed commits, and untested code. Tracking estimated vs actual effort across sessions builds an evidence base for better calibration.

---

### 1.2 Information Processing Styles

#### Serial vs Parallel Processing

**What it is.** Whether the user processes information sequentially (one thread at a time, step by step) or in parallel (multiple threads, jumping between contexts).

**Observable signals (serial).** User completes one file before moving to the next. User finishes debugging before starting a new feature. User asks the AI to address one question before posing the next. User gets frustrated when multiple issues surface simultaneously.

**Observable signals (parallel).** User opens multiple files and edits across them in the same exchange. User interrupts a debugging session to fix something unrelated they noticed. User asks compound questions spanning multiple topics. User switches projects mid-session without closing out the first.

**Why it matters.** Serial processors benefit from structured task sequencing. Parallel processors benefit from clear bookmarks for interrupted threads. Neither is better — but mismatched workflow guidance wastes energy.

#### Detail-Oriented vs Big-Picture

**What it is.** Whether the user naturally focuses on implementation specifics or system-level architecture.

**Observable signals (detail).** User asks about specific function signatures, exact types, precise error messages. User reviews diffs line by line. User catches minor inconsistencies that others miss. User struggles to articulate the overall system design but produces correct implementations.

**Observable signals (big-picture).** User starts with architecture before touching code. User asks "how does this connect to..." frequently. User sketches data flows and system boundaries. User may miss implementation details (edge cases, error handling) while correctly structuring the system. User references patterns and principles more than specific APIs.

**Why it matters.** Detail-oriented users may need prompting to consider architectural implications. Big-picture users may need prompting to handle edge cases. Tracking this reveals where the user's natural attention goes and where blind spots live.

---

### 1.3 Learning Preferences

#### Experiential Learning

**What it is.** Learning primarily by doing — building, breaking, debugging, shipping.

**Observable signals.** User says "let me just try it." User builds prototypes before reading documentation. User learns APIs by calling them and reading error messages rather than reading guides first. User retains knowledge better after building with a technology than after reading about it.

**Why it matters.** Experiential learners produce more corrections early (learning through mistakes) but achieve deeper retention. Their learning curve is steep and noisy. Scribe should track whether early corrections in a new domain decline over time — that is the learning signal.

#### Conceptual Learning

**What it is.** Learning primarily by understanding principles, mental models, and theory before applying them.

**Observable signals.** User reads documentation extensively before writing code. User asks "why does this work?" not just "how do I use it?" User draws diagrams or describes architectures before implementation. User wants to understand the underlying system, not just the API surface.

**Why it matters.** Conceptual learners produce fewer early corrections but may be slower to ship. Their growth shows in decision quality — better architectural choices, fewer reversals. Scribe should track decision reversal rates as a learning signal.

#### Observational Learning

**What it is.** Learning primarily by watching others, reading code, and absorbing patterns from examples.

**Observable signals.** User says "show me an example." User reads existing codebases to understand patterns before building. User asks the AI to demonstrate rather than explain. User copies patterns from working code and adapts them. User prefers reference implementations over documentation.

**Why it matters.** Observational learners benefit most from well-documented codebases and consistent patterns. Their growth shows in pattern recognition — identifying the right approach by analogy. Scribe should track whether the user's pattern matching improves across domains.

---

### 1.4 Attention and Focus Models

#### Sustained Attention

**What it is.** The ability to maintain focus on a single task or problem over an extended period.

**Observable signals.** User works on one problem for 45+ minutes without switching context. User returns to the same problem across multiple exchanges without losing the thread. User ignores unrelated issues that surface during focused work. Session has a single clear arc from problem identification to resolution.

**Why it matters.** Sustained attention is the prerequisite for deep work and complex problem-solving. Users with strong sustained attention produce higher-quality solutions but may miss peripheral issues. Tracking attention duration reveals the user's capacity for complex work.

#### Selective Attention

**What it is.** The ability to focus on relevant information while filtering irrelevant noise.

**Observable signals.** User quickly identifies the relevant section of a long error log. User skips boilerplate code and focuses on the logic that matters. User ignores cosmetic issues while debugging functional ones. User asks targeted questions rather than broad ones.

**Why it matters.** Strong selective attention accelerates debugging and review. Weak selective attention leads to distraction by irrelevant details and slower resolution. Tracking this reveals the user's ability to triage information effectively.

#### Divided Attention

**What it is.** The attempt to focus on multiple streams simultaneously, with associated quality degradation in each.

**Observable signals.** User asks about unrelated topics within the same exchange. User references multiple projects without closing out any of them. Quality of decisions drops when working on multiple fronts. User makes errors characteristic of distraction — typos, wrong file paths, referencing the wrong project context.

**Why it matters.** Divided attention is never as effective as sequential focused attention. When Scribe observes divided attention, it signals cognitive overload. This correlates with higher correction rates and lower-quality entries. The pattern itself is worth surfacing.

---

## 2. Motivational Patterns

What drives the user's behavior, what sustains their effort, and what causes them to disengage.

---

### 2.1 Intrinsic vs Extrinsic Motivation

#### Intrinsic Motivation

**What it is.** Behavior driven by internal satisfaction — the work itself is the reward. Curiosity, mastery, craft, and meaning.

**Observable signals.** User explores beyond the requirements. User refactors working code for elegance or clarity. User asks "what if we also..." without external pressure. User expresses satisfaction with the work itself ("this is clean," "I like how this turned out"). User spends extra time on internal tooling nobody else sees.

**Why it matters.** Intrinsic motivation produces the deepest learning and highest-quality work. It is also sustainable — it does not depend on external validation. Users driven by intrinsic motivation are more likely to develop skills independently. Sessions driven by intrinsic motivation produce the most valuable learning entries.

#### Extrinsic Motivation

**What it is.** Behavior driven by external outcomes — deadlines, client expectations, revenue, status, obligation.

**Observable signals.** User references deadlines, client expectations, or stakeholder pressure. User chooses speed over quality when not explicitly constrained. User says "just make it work" or "we need to ship this." User defers quality improvements to a "later" that rarely arrives. User asks how long something will take before deciding whether to do it.

**Why it matters.** Extrinsic motivation is real and valid — shipping matters. But sessions dominated by extrinsic pressure correlate with higher correction rates, more technical debt, and fewer learnings. Tracking the balance between intrinsic and extrinsic across sessions reveals whether the user has time for growth or is always in survival mode.

---

### 2.2 Goal Orientation

#### Mastery Orientation

**What it is.** Pursuing competence and understanding as the primary goal. Success is measured by learning and improvement.

**Observable signals.** User asks "why did that work?" after solving a problem. User spends time understanding a solution, not just implementing it. User reads documentation about adjacent concepts, not just the immediate need. User says "I want to understand this" or "let me learn this properly."

**Why it matters.** Mastery-oriented users accumulate durable skills. Their corrections decrease over time within a domain because they internalize principles, not just procedures. Tracking mastery behaviors reveals long-term growth potential.

#### Performance Orientation

**What it is.** Pursuing demonstrated competence relative to others. Success is measured by output, speed, and visible results.

**Observable signals.** User focuses on shipping features over understanding systems. User asks "what's the fastest way to do this?" User counts features completed, PRs merged, or lines shipped. User compares current velocity to past sessions. User skips understanding once something works.

**Why it matters.** Performance orientation produces high output but shallow learning. Corrections may not decrease over time because the underlying principles are not internalized. This is not inherently negative — some contexts reward output over depth — but the pattern has consequences for long-term growth.

#### Approach vs Avoidance

**What it is.** Whether goals are framed as moving toward desired outcomes (approach) or away from feared outcomes (avoidance).

**Observable signals (approach).** User says "I want to build..." or "let's add..." User initiates new features proactively. User describes goals in terms of what they will gain.

**Observable signals (avoidance).** User says "I don't want this to break" or "we need to avoid..." User prioritizes preventing failure over achieving success. User over-tests obvious cases while under-testing edge cases. User defers risky changes indefinitely.

**Why it matters.** Approach-oriented users take more risks and learn faster but may under-invest in stability. Avoidance-oriented users produce more stable systems but may stagnate. The balance shifts across sessions — tracking it reveals whether the user is growing or defending.

---

### 2.3 Persistence Profiles

#### Grit

**What it is.** Sustained effort and interest toward long-term goals despite setbacks, plateaus, and the absence of immediate rewards.

**Observable signals.** User returns to a difficult problem across multiple sessions. User does not abandon a project when progress slows. User pushes through boring maintenance work because it serves the larger goal. User maintains focus on a long-term vision even when individual sessions feel unproductive.

**Why it matters.** Grit is the strongest predictor of project completion. Users with high grit finish what they start. Low grit manifests as many started projects with few finished ones. Scribe should track project completion rates as a grit indicator.

#### Resilience

**What it is.** The ability to recover from failures, setbacks, and corrections without losing momentum or motivation.

**Observable signals.** User treats bugs as puzzles rather than frustrations. User recovers quickly from failed deploys or broken builds. User does not spiral into self-blame after mistakes. User says "okay, let's try another approach" rather than "this is impossible."

**Why it matters.** Resilience determines whether corrections produce growth or discouragement. Users who bounce back quickly accumulate fewer emotional costs from mistakes and maintain a healthier relationship with the work. Low resilience manifests as avoidance of the domain where failure occurred.

#### Pivot vs Push Through

**What it is.** The judgment of when to abandon a failing approach and try something new vs when to persevere through difficulty.

**Observable signals (premature pivot).** User switches approaches after minor setbacks. User tries a new library or framework every time they hit an obstacle. User has many partial implementations and few complete ones. User says "maybe we should just use X instead" before exhausting the current approach.

**Observable signals (excessive persistence).** User continues debugging a fundamentally flawed approach for 45+ minutes. User applies patch after patch instead of reconsidering the design. User refuses to consider alternatives after 3+ failed attempts with the same approach.

**Why it matters.** The pivot/persist judgment is one of the highest-value skills in building. Neither extreme is productive. Tracking the outcomes of pivot decisions (did the new approach work?) and persist decisions (did persistence pay off?) builds evidence for better calibration.

---

### 2.4 Delay Discounting

**What it is.** Preferring immediate, smaller rewards over delayed, larger rewards. In builders, this manifests as preferring to ship visible features now over doing foundational work that pays off later.

**Observable signals.** User builds new features instead of writing tests. User skips documentation to start the next feature. User avoids refactoring in favor of new functionality. User defers admin tasks (dependency updates, security patches, data cleanup) indefinitely. User says "I'll do that later" for non-exciting tasks and "let's build this now" for exciting ones.

**Why it matters.** Delay discounting is the root cause of technical debt, missing tests, missing documentation, and accumulating admin backlog. It is the most common pattern in builders and one of the hardest to correct because the immediate reward (shipping a feature) is psychologically tangible while the delayed cost (maintenance burden, production bugs) is abstract until it becomes a crisis. Tracking the ratio of foundational work to feature work reveals the user's discount rate.

---

### 2.5 Self-Determination Theory

#### Autonomy

**What it is.** The need to feel ownership and control over one's work and decisions.

**Observable signals (high autonomy need).** User pushes back on AI-driven decisions. User says "I want to decide" or "let me think about this." User modifies AI suggestions rather than accepting them wholesale. User initiates work without being prompted.

**Observable signals (low autonomy).** User asks the AI to make decisions for them. User accepts every suggestion without modification. User says "just do whatever you think is best." User waits for direction rather than initiating.

**Why it matters.** Autonomy level directly maps to the `growth.autonomy` field in entries. Tracking autonomy over time reveals whether the user is developing independent judgment or becoming dependent on the AI. Growth means increasing autonomy in domains where the user was previously guided.

#### Competence

**What it is.** The need to feel effective, capable, and growing in skill.

**Observable signals (competence need met).** User tackles progressively harder problems. User applies patterns from one domain to another. User corrects the AI when it makes mistakes. User teaches or explains concepts to others.

**Observable signals (competence need threatened).** User retreats to familiar patterns after a failure. User avoids domains where they have struggled. User's language becomes uncertain in areas where they used to be confident. User asks for more hand-holding than usual after a setback.

**Why it matters.** When the competence need is threatened, learning stops. The user enters a defensive mode that produces no growth entries and no meaningful learnings. Recognizing this state allows Scribe to note it honestly — not to intervene, but to create an accurate record that the Reader can surface later.

#### Relatedness

**What it is.** The need to feel connected to others, to contribute to a shared effort, and to have one's contributions recognized.

**Observable signals.** User references team members by name. User considers how their work affects collaborators. User asks "what does [person] think?" or "how will this affect [person]'s work?" User invests in documentation and code clarity for future readers. User engages with packet exchanges. User mentions feedback from stakeholders.

**Why it matters.** Relatedness drives collaboration quality. Users with strong relatedness needs produce better documentation, more considerate architectural decisions, and more effective packet exchanges. Users whose relatedness need is unmet may disengage from shared projects.

---

## 3. Work Patterns

Observable rhythms, states, and conditions of the user's working behavior.

---

### 3.1 Flow States

**What it is.** A state of optimal experience where challenge matches skill, attention is fully absorbed, and the sense of time distorts. Defined by Csikszentmihalyi as requiring clear goals, immediate feedback, and a balance between challenge and ability.

**Observable signals (in flow).** User produces high-quality code in rapid succession without pausing for direction. User's requests become terse and action-oriented — commands, not questions. User does not reference external context (deadlines, stakeholders) — fully absorbed in the work itself. Session has long stretches without conversational exchanges — just building. User does not ask "should I?" — they just do. Error recovery is fast and decisive.

**Observable signals (flow disrupted).** User was in a productive streak and then received an external interruption (different project, different concern). Quality drops noticeably after the interruption. User takes multiple exchanges to re-establish context. User says "where was I?" or re-reads recent output to reorient.

**Observable signals (flow impossible).** Task is too easy (no challenge). Task is too hard (no skill match). Environment is fragmented (multiple unrelated requests in the same session). User is in "manager mode" — coordinating, not building.

**Why it matters.** Flow is when the best work happens. Tracking flow frequency, duration, and disruption causes reveals the conditions under which the user does their deepest work. Sessions with flow produce fewer corrections and higher-quality entries. Sessions without flow produce more corrections and lower-quality output. This is one of the highest-signal observations Scribe can make.

---

### 3.2 Context-Switching Costs

**What it is.** The cognitive penalty of moving between unrelated tasks. Research shows 15-25 minutes to fully re-engage with a complex task after interruption, and cognitive residue from the interrupted task degrades performance on the new one.

**Observable signals.** User switches between unrelated projects within a session. User makes errors characteristic of the previous context (wrong variable names, wrong project references, wrong database). User takes several exchanges to orient after switching. User's decision quality drops in the first 10-15 minutes after a switch. User references the wrong codebase or file structure.

**Why it matters.** Context-switching is one of the most expensive cognitive operations. Users who context-switch frequently produce more corrections per unit of productive time. Tracking switch frequency and post-switch error rates reveals the true cost of multitasking for this specific user.

---

### 3.3 Energy Cycles

**What it is.** Humans operate on ultradian rhythms — approximately 90-minute cycles of higher and lower cognitive energy. Performance degrades predictably as a session extends beyond the user's natural rhythm.

**Observable signals (high energy).** User's requests are clear and specific. User makes decisions quickly. User catches errors proactively. User initiates new work without prompting. User's code quality is consistent.

**Observable signals (low energy).** User's requests become vague or unfocused. User defers decisions ("let's figure this out later"). User misses obvious errors. User asks for help with tasks they normally handle independently. Session duration extends without proportional output increase. User accepts AI output without review.

**Observable signals (energy depletion).** Late-session quality drop. User says "let's just get this done." User skips testing or verification steps. User makes uncharacteristic mistakes. User's language becomes shorter and less precise.

**Why it matters.** Energy is finite and cyclical. Tracking when corrections cluster within sessions (early, middle, late) reveals the user's natural performance window. Users who learn to respect their energy cycles make fewer late-session mistakes.

---

### 3.4 Productivity Rhythms

#### Maker vs Manager Schedule

**What it is.** Maker schedule: long uninterrupted blocks (4+ hours) for creative and technical work. Manager schedule: time divided into short meetings and coordination slots. Most builders need maker time to produce quality work.

**Observable signals (maker mode).** Long sessions with deep focus on a single domain. User produces substantial output. User is annoyed by interruptions. User builds, debugs, refactors, ships.

**Observable signals (manager mode).** Short sessions with diverse topics. User coordinates, reviews, directs. User makes decisions about what others should do. User manages dependencies, timelines, stakeholder expectations.

**Why it matters.** Users in permanent manager mode never enter flow and never produce deep work. Users in permanent maker mode may neglect coordination and stakeholder management. Tracking the ratio reveals whether the user has sufficient maker time for the work they are trying to do.

#### Batch Processing vs Reactive Work

**What it is.** Whether the user groups similar tasks together (batch) or handles them as they arise (reactive).

**Observable signals (batch).** User does all database migrations in one session. User addresses all bugs from a category before moving to the next. User dedicates a session to documentation, testing, or refactoring as a focused block.

**Observable signals (reactive).** User addresses issues as they discover them, regardless of type. User interrupts feature work to fix a bug they just noticed. User's session has no coherent theme — it is a sequence of unrelated responses to stimuli.

**Why it matters.** Batch processing is more efficient for most technical work because it minimizes context-switching. Reactive work is appropriate for urgent issues but expensive as a default mode. Tracking this reveals whether the user's work patterns are deliberate or stimulus-driven.

---

### 3.5 Task Completion Patterns

#### Starting Strong, Fading

**What it is.** High energy and output at the beginning of a task or session, with declining quality and effort toward the end.

**Observable signals.** First 30 minutes produce clean code and clear decisions. Quality degrades in the second half. User skips tests and verification late in sessions. User says "let's just ship it" without the rigor applied at the start. Error rate increases as the session progresses.

**Why it matters.** This pattern produces bugs in the last 20% of features — the part that was rushed. Tracking where corrections cluster within the timeline of a feature reveals this pattern.

#### Slow Start, Strong Finish

**What it is.** Low initial output as the user orients, followed by accelerating productivity and quality as they warm up.

**Observable signals.** First several exchanges are exploratory — reading files, asking questions, reviewing context. User's productivity and confidence increase as the session progresses. Best work happens in the second half. User needs time to "get into it."

**Why it matters.** Users with this pattern produce their best work after a warm-up period. Sessions that are too short may never reach their productive peak. This is not inefficiency — it is the user's natural loading process.

#### Steady Pace

**What it is.** Consistent output and quality throughout a session, without significant peaks or valleys.

**Observable signals.** Error rate and decision quality are stable from start to finish. User takes natural breaks without quality impact. Output is predictable and reliable. No "rush to finish" pattern at the end.

**Why it matters.** Steady pace is the most sustainable pattern but may indicate the user is not pushing into challenging territory. Consistent quality within the comfort zone is different from consistent quality at the growth edge.

---

### 3.6 Approach vs Avoidance at Work

**What it is.** Whether the user moves toward goals they want to achieve or away from problems they want to escape.

**Observable signals (approach).** User initiates proactive improvements. User builds features before they are requested. User tackles the hardest problem first. User seeks out challenging work.

**Observable signals (avoidance).** User prioritizes tasks that avoid negative consequences (fix the prod bug, address the client complaint) over growth tasks. User defers uncomfortable work (refactoring, testing, documentation) in favor of building new things. User structures sessions to avoid topics that are difficult or boring.

**Why it matters.** Approach-oriented sessions produce more growth and learning. Avoidance-oriented sessions produce stability but not development. The balance between them reveals whether the user is building for the future or managing the present.

---

## 4. Interpersonal Patterns

How the user communicates, collaborates, leads, and responds to others.

---

### 4.1 Communication Styles

#### Direct vs Indirect

**What it is.** Whether the user states their needs, opinions, and decisions explicitly or wraps them in hedging, questions, and suggestions.

**Observable signals (direct).** User gives clear instructions: "Do X." User states opinions without qualifiers: "This approach is wrong." User says "no" to suggestions that do not fit. User's feedback is specific and actionable.

**Observable signals (indirect).** User phrases directives as questions: "What do you think about maybe doing X?" User hints at dissatisfaction rather than stating it: "That's interesting, but..." User agrees with suggestions they do not like and then redirects later. User avoids explicit rejection.

**Why it matters.** Direct communicators produce clearer requirements and faster feedback loops. Indirect communicators may produce ambiguous requirements that lead to rework. Tracking this helps Scribe accurately attribute decisions — an indirect "what if we..." may actually be a directive.

#### High-Context vs Low-Context

**What it is.** Whether the user assumes shared context and communicates tersely (high-context) or provides full context explicitly (low-context).

**Observable signals (high-context).** User gives brief instructions assuming the AI remembers prior sessions. User references decisions by shorthand ("use the medallion pattern"). User says "do it the usual way." User's messages are short and implication-heavy.

**Observable signals (low-context).** User provides full context with every request. User restates requirements even when previously discussed. User includes file paths, function names, and expected behaviors explicitly. User does not assume shared understanding.

**Why it matters.** High-context users work faster when the AI maintains context but are vulnerable to context loss (compaction, new sessions). Low-context users are more robust to context loss but spend more time on communication. Tracking this reveals the user's expectations about continuity and shared understanding.

---

### 4.2 Conflict Approaches

#### Competing

**What it is.** Asserting one's own position at the expense of others. Win-lose orientation.

**Observable signals.** User overrides AI suggestions without engaging with the reasoning. User says "just do it my way." User escalates when challenged. User views disagreement as a contest rather than a collaboration.

#### Collaborating

**What it is.** Working with the other party to find a solution that fully satisfies both concerns. Win-win orientation.

**Observable signals.** User asks "why do you suggest that?" before deciding. User incorporates AI reasoning into their decision. User proposes compromises that address both concerns. User views disagreement as information.

#### Compromising

**What it is.** Finding a middle ground where each party gives up something. Partial win-partial win.

**Observable signals.** User says "let's do half of what you suggest and half of what I want." User settles for adequate solutions rather than pushing for optimal ones. User splits differences rather than resolving underlying tensions.

#### Avoiding

**What it is.** Withdrawing from or postponing conflict. Neither party's concerns are addressed.

**Observable signals.** User says "let's deal with this later" when disagreement arises. User changes the subject when the AI raises concerns. User ignores warnings about edge cases or risks. User defers difficult decisions indefinitely.

#### Accommodating

**What it is.** Yielding to the other party's position at the expense of one's own concerns. Lose-win orientation.

**Observable signals.** User accepts every AI suggestion without pushback. User abandons their approach immediately when the AI proposes an alternative. User says "you know best" on topics where they have relevant expertise.

**Why it matters (all conflict approaches).** Conflict approach reveals how the user handles disagreement with the AI and with collaborators. Persistent competing produces suboptimal solutions because AI reasoning is never considered. Persistent accommodating produces AI-dependent behavior. Collaborating is the approach most correlated with growth. The user's default conflict approach often shifts under stress — tracking this shift is diagnostic.

---

### 4.3 Leadership Tendencies

#### Directive

**What it is.** Providing specific instructions, defining tasks precisely, and monitoring execution closely.

**Observable signals.** User gives step-by-step instructions. User reviews every line of output. User says "do exactly this." User specifies implementation details rather than outcomes.

#### Participative

**What it is.** Involving the AI as a genuine collaborator — soliciting input, discussing alternatives, making joint decisions.

**Observable signals.** User asks "what approach would you take?" User discusses tradeoffs before deciding. User modifies AI suggestions rather than accepting or rejecting wholesale. User credits the AI's contribution in their reasoning.

#### Delegative

**What it is.** Providing the goal and leaving execution decisions to the AI.

**Observable signals.** User says "build this feature" without specifying implementation. User trusts the AI to choose the approach. User reviews output rather than directing the process. User defines "what" and leaves "how" open.

#### Coaching

**What it is.** Using the AI interaction as an opportunity to develop their own skills — asking for explanations, requesting alternatives, learning through the process.

**Observable signals.** User asks "why does this work?" or "what would happen if...?" User requests multiple approaches to compare. User tries to solve the problem themselves before asking for help. User asks the AI to explain its reasoning.

**Why it matters (all leadership tendencies).** Leadership tendency determines the quality of AI collaboration. Directive users maintain control but may miss better AI-generated solutions. Delegative users leverage AI capabilities but may not learn from the interaction. Coaching users maximize learning per session. Tracking leadership tendency by domain reveals where the user is confident (delegative) vs uncertain (directive) vs actively growing (coaching).

---

### 4.4 Collaboration Dynamics

#### Labor Division

**What it is.** How the user splits work between themselves and the AI, and between themselves and human collaborators.

**Observable signals.** User handles architecture, delegates implementation. Or: user delegates architecture, handles implementation. User keeps certain file types (config, CSS, SQL) and delegates others. User divides work with collaborators by domain, by feature, or by availability.

**Why it matters.** Labor division reveals the user's perceived strengths and weaknesses. Consistent delegation of a domain means the user either trusts the AI/collaborator in that area or avoids it. Either way, it is a signal.

#### Credit and Blame Attribution

**What it is.** How the user attributes success and failure in collaborative work.

**Observable signals.** User says "I built this" vs "we built this." User says "the AI got this wrong" vs "this approach did not work." User references collaborator contributions in positive or negative terms. User acknowledges their own mistakes or deflects them.

**Why it matters.** Attribution patterns correlate with locus of control (see Growth Patterns). Internal attribution for failures drives learning. External attribution for failures stalls growth.

---

### 4.5 Trust Building and Maintenance

**What it is.** The process by which the user extends, calibrates, and sometimes revokes trust in the AI and in collaborators.

**Observable signals (trust building).** User gradually increases delegation scope. User stops reviewing output in domains where the AI has proven reliable. User refers to past successful interactions as evidence. User says "you handled that well."

**Observable signals (trust eroding).** User starts re-reviewing output they previously accepted. User adds more constraints and instructions after an error. User says "check this carefully" or "are you sure?" User reduces delegation scope after a mistake.

**Observable signals (trust rupture).** User reverts to fully directive mode after a significant AI error. User says "I can't trust this" or "I'll do it myself." User stops asking for suggestions.

**Why it matters.** Trust calibration reveals the user's risk tolerance and their model of AI reliability. Well-calibrated trust is neither blind nor withholding — it matches delegation to demonstrated competence. Tracking trust patterns across domains reveals where the AI is earning or losing the user's confidence.

---

### 4.6 Feedback Reception

#### Positive Feedback Reception

**What it is.** How the user processes and responds to validation, praise, or confirmation of good work.

**Observable signals.** User incorporates positive feedback as confirmation to continue the approach. Or: user dismisses positive feedback as flattery and demands harder challenges. Or: user depends on positive feedback for motivation and stalls without it.

#### Negative Feedback Reception

**What it is.** How the user processes corrections, criticism, or evidence of mistakes.

**Observable signals (growth response).** User engages with the feedback, asks clarifying questions, and modifies behavior. User says "you're right" and adjusts. User treats corrections as data points, not personal attacks.

**Observable signals (defensive response).** User explains away the mistake. User says "that's not what I meant" or "the requirements were unclear." User shifts blame to tools, documentation, or the AI. User ignores the feedback and continues the original approach.

**Observable signals (withdrawal response).** User goes quiet after negative feedback. User changes the subject. User ends the session shortly after a correction. User avoids the domain where the correction occurred in subsequent sessions.

**Why it matters.** Feedback reception is the gatekeeper of growth. Users who engage with negative feedback grow fastest. Users who defend or withdraw from it grow slowest. Scribe should track the user's response to corrections as one of the most important growth indicators.

---

## 5. Growth Patterns

Trajectories, plateaus, breakthroughs, and regressions in the user's development over time.

---

### 5.1 Learning Curves

**What it is.** The predictable stages of skill acquisition: steep initial climb (rapid progress, many corrections), plateau (diminishing returns per unit effort), breakthrough (sudden capability jump), and mastery (consistent high performance with occasional refinement).

**Observable signals (steep climb).** High correction rate in a new domain. Frequent "I didn't know that" learnings. Rapid improvement between sessions. Visible struggle followed by resolution. User asks many foundational questions.

**Observable signals (plateau).** Correction rate has stabilized but not reached zero. No new learnings in the domain for 3+ sessions. User is competent but not improving. Work is correct but not innovative. The user can execute but not optimize.

**Observable signals (breakthrough).** User solves a problem type they have never solved before. User applies a concept from one domain to another for the first time. User's approach shifts from procedural to principled. A formerly difficult task becomes routine.

**Observable signals (mastery).** User makes near-zero corrections in the domain. User teaches or explains concepts confidently. User handles edge cases intuitively. User innovates within the domain — new patterns, better approaches.

**Why it matters.** Knowing where the user is on the learning curve for each domain allows Scribe to set accurate complexity ratings, identify genuine breakthroughs, and distinguish between plateau (needs new challenge) and mastery (domain is handled).

---

### 5.2 Plateau Signals

**What it is.** Indicators that the user has stopped growing in a domain — not because they have mastered it, but because they have settled into comfortable routine.

**Observable signals.** Flat complexity ratings across sessions (always "routine" or always "moderate"). No new learnings logged in a domain for 3+ sessions. User solves the same class of problem the same way every time. User does not seek out new approaches or tools. User's work is competent but templated — no variation, no experimentation. Declining engagement with the domain (shorter sessions, less attention to detail).

**Why it matters.** Plateaus are invisible to the user. They feel like competence — "I can do this easily" — but they are actually stagnation. Scribe's longitudinal view can detect plateaus that feel like mastery to the user. The Reader surfaces these during growth reflections.

---

### 5.3 Comfort Zone Boundaries

**What it is.** The domains, problem types, and complexity levels where the user operates confidently versus where they hesitate, avoid, or struggle.

**Observable signals (inside comfort zone).** User works quickly and decisively. User does not ask for help. User's language is confident. User initiates rather than waits. User handles edge cases without prompting.

**Observable signals (at comfort zone edge).** User asks more questions. User checks their work more carefully. User's pace slows. User tries solutions but second-guesses them. User says "I think this is right" instead of "this is right."

**Observable signals (outside comfort zone).** User becomes dependent on AI guidance. User's language becomes uncertain. User avoids the task or postpones it. User asks the AI to take over rather than guiding. User's error rate increases significantly.

**Why it matters.** Growth happens at the edge of the comfort zone — not inside it (too easy, no learning) and not far outside it (too hard, no progress, possible discouragement). Tracking where the user's comfort zone boundaries are for each domain reveals where growth opportunities exist and where the user might need support to stretch.

---

### 5.4 Breakthrough Indicators

**What it is.** Signals that the user has achieved a genuine capability jump — not incremental improvement but a qualitative shift in how they approach a class of problem.

**Observable signals.** User solves a problem type they have failed at before. User transfers a skill from one domain to another unprompted. User's approach shifts from procedural ("do step 1, then step 2") to principled ("apply pattern X because the problem has properties Y and Z"). User teaches a concept they recently learned. User builds something that combines multiple skills in a novel way. User catches an error that they would not have caught in prior sessions.

**Why it matters.** Breakthroughs are the most valuable growth events. They are rare, real, and measurable. Scribe should log them at "challenging" or "breakthrough" complexity — never inflated. A true breakthrough changes the user's capabilities permanently. It should be traceable from earlier corrections and learnings in the same domain.

---

### 5.5 Regression Signals

**What it is.** Returning to old patterns after demonstrating improvement. Not the same as a one-time mistake — regression is a sustained return to a previous level of performance.

**Observable signals.** User repeats a correction type that had been resolved for 3+ sessions. User reverts to an approach they had explicitly abandoned after learning a better one. User's autonomy drops in a domain where it had been increasing. User asks for help with tasks they handled independently in recent sessions. Quality of decisions in a domain declines after a period of improvement.

**Why it matters.** Regression is normal — it happens under stress, fatigue, or when cognitive load is high. But persistent regression (3+ sessions) signals that the improvement was superficial rather than internalized. The correction tracker is the primary tool for detecting regression — it shows whether resolved patterns re-emerge.

---

### 5.6 Zeigarnik Effect

**What it is.** Unfinished tasks create persistent cognitive load. The mind keeps returning to incomplete work, consuming attention and reducing capacity for current tasks.

**Observable signals.** User references unfinished work from prior sessions unprompted. User's first request in a new session is to complete something left from the previous session. User mentions feeling "behind" or having a "backlog." User says "I still need to..." about tasks from days or weeks ago. User context-switches to an incomplete task mid-session even when not prompted.

**Why it matters.** The Zeigarnik effect explains why unfinished features, pending refactors, and deferred admin tasks create psychological drag even when they have no immediate deadline. Users carrying high Zeigarnik load produce lower-quality work on their current task. Tracking unfinished task references reveals the user's cognitive debt.

---

### 5.7 Builder's Bias

**What it is.** The preference for creating new things over maintaining, finishing, or polishing existing ones. A specific manifestation of delay discounting combined with novelty-seeking.

**Observable signals.** User starts new features before finishing current ones. User has multiple branches in progress. User says "let's build..." more than "let's finish..." User is energized by greenfield work and disengaged by maintenance. User defers bug fixes, documentation, and cleanup in favor of new functionality. User's commit history shows many "add" commits and few "fix" or "refactor" commits.

**Why it matters.** Builder's bias is the most common pattern in makers and one of the most destructive for long-term project health. It produces codebases with many features, few tests, sparse documentation, and accumulating technical debt. It is also deeply satisfying in the moment, which makes it resistant to correction. Tracking the ratio of building-new vs maintaining-existing across sessions reveals the severity of this bias.

---

### 5.8 Locus of Control

#### Internal Locus

**What it is.** Attributing outcomes — both success and failure — to one's own actions, decisions, and effort.

**Observable signals.** User says "I should have tested that" after a bug, not "the framework has a bug." User says "I need to learn X" rather than "X is poorly documented." User takes ownership of mistakes. User credits their own effort for successes. User modifies their behavior after corrections.

#### External Locus

**What it is.** Attributing outcomes to external factors — tools, documentation, other people, luck, or circumstances.

**Observable signals.** User blames tools for failures ("Supabase is broken," "the docs are wrong"). User credits luck or external factors for successes ("the API happened to work"). User says "I can't do X because Y" where Y is external. User does not modify behavior after corrections because the cause was "not my fault."

**Why it matters.** Internal locus of control is the strongest predictor of growth. Users who own their outcomes learn from them. Users who externalize outcomes do not change behavior because, in their model, their behavior was not the cause. Tracking attribution language reveals the user's locus of control, which predicts whether corrections will drive improvement or be dismissed.

---

## Observation Protocol

When `behavioral_tracking` is enabled, Scribe reads this library on session start and observes through all lenses simultaneously. The following protocol governs how observations translate into the `behavioral` field of entries.

### What to write

- `drive_state`: Infer from the overall session behavior — is the user building, firefighting, avoiding, maintaining, exploring, or closing? Use the motivational and work pattern lenses.
- `energy`: Infer from request quality, decision speed, and error rate. Use the energy cycles framework.
- `triggers`: Identify the specific stimuli that prompted the observed behavior. Be concrete — "client deadline mentioned at exchange 3" not "external pressure."
- `avoidance_signals`: Note tasks the user mentioned but deferred, or domains they steered away from. Use the comfort zone and approach/avoidance lenses.
- `language_markers`: Capture specific phrases that reveal mindset — "I should have," "this always breaks," "just make it work," "I want to understand." These are raw data.
- `cognitive_load`: Infer from divided attention signals, error patterns, and Zeigarnik references. Focused, moderate, or overloaded.
- `pattern_flags`: Flag recurring patterns using the specific names from this library — "sunk-cost-fallacy," "builder's-bias," "context-switch-cost," "plateau-signal." These are searchable across entries.
- `notes`: Free-form observation connecting multiple signals into a coherent behavioral picture for this specific entry. Be specific, not generic. One sentence connecting observed behavior to a framework from this library is worth more than a paragraph of vague commentary.

### What not to write

- Never diagnose. Scribe observes patterns, not pathologies.
- Never judge. "User is exhibiting confirmation bias" is an observation. "User is being stubborn" is a judgment.
- Never prescribe. Behavioral observations are data for the Reader, not directives for the user.
- Never fabricate signals. If the session provides no behavioral data, leave the field minimal. An empty `pattern_flags` array is better than a speculative one.

### Signal strength

Not every pattern applies to every session. Most sessions will activate 2-4 patterns from this library. A session that activates more than 6 simultaneously is likely overloaded — choose the strongest signals and note the rest in the `notes` field.

Strength thresholds:
- **Strong signal**: Multiple observable instances within the session, consistent with prior sessions.
- **Moderate signal**: One or two instances, may or may not be consistent with prior pattern.
- **Weak signal**: Single ambiguous instance. Note in `notes` if at all — do not flag as a pattern.

Only flag patterns at moderate or strong signal strength. Weak signals are noise unless they become moderate over multiple sessions.
