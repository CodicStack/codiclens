# No UI tests

This target is empty on purpose.

It previously held the two Xcode template tests — `testExample`,
`testLaunchPerformance` and `testLaunch` — none of which asserted anything about
Codiclens. What they did do was launch the app five times per run, and every
launch of a build that has not been granted Accessibility raises the system
permission dialog. That made an ordinary `xcodebuild test` a stream of
permission prompts, and the repeated launch-and-terminate cycle was also the
only thing that ever reported the app failing to quit.

Codiclens is an `LSUIElement` app with no window until a hotkey summons one, so
XCUITest has very little to hold on to. The behaviour worth testing — the phase
machine, the Index, the emoji dataset, query handling — is covered by
`codiclensTests`, which needs no permissions and no automation.

If UI coverage is added later, it must assert something specific and must not
re-introduce a bare `app.launch()` performance measurement.
