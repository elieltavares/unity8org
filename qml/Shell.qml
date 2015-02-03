/*
 * Copyright (C) 2013-2014 Canonical, Ltd.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; version 3.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import QtQuick 2.0
import QtQuick.Window 2.0
import AccountsService 0.1
import GSettings 1.0
import Unity.Application 0.1
import Ubuntu.Components 0.1
import Ubuntu.Components.Popups 1.0
import Ubuntu.Gestures 0.1
import Ubuntu.SystemImage 0.1
import Ubuntu.Telephony 0.1 as Telephony
import Unity.Connectivity 0.1
import Unity.Launcher 0.1
import Utils 0.1
import LightDM 0.1 as LightDM
import Powerd 0.1
import SessionBroadcast 0.1
import "Greeter"
import "Launcher"
import "Panel"
import "Components"
import "Notifications"
import "Stages"
import "Panel/Indicators"
import "Wizard"
import Unity.Notifications 1.0 as NotificationBackend
import Unity.Session 0.1
import Unity.DashCommunicator 0.1

Item {
    id: shell

    // to be set from outside
    property int orientationAngle: 0
    property int orientation
    property int primaryOrientation
    property int nativeOrientation
    property real nativeWidth
    property real nativeHeight
    property alias indicatorAreaShowProgress: panel.indicatorAreaShowProgress
    property bool beingResized
    property string usageScenario: "phone" // supported values: "phone", "tablet" or "desktop"
    function updateFocusedAppOrientation() {
        applicationsDisplayLoader.item.updateFocusedAppOrientation();
    }
    function updateFocusedAppOrientationAnimated() {
        applicationsDisplayLoader.item.updateFocusedAppOrientationAnimated();
    }

    // to be read from outside
    readonly property int mainAppWindowOrientationAngle:
            applicationsDisplayLoader.item ? applicationsDisplayLoader.item.mainAppWindowOrientationAngle : 0

    readonly property bool orientationChangesEnabled: panel.indicators.fullyClosed
            && (applicationsDisplayLoader.item && applicationsDisplayLoader.item.orientationChangesEnabled)
            && !greeter.showAnimation.running
            && !greeter.hideAnimation.running

    property bool startingUp: true
    Timer { id: finishStartUpTimer; interval: 500; onTriggered: startingUp = false }

    property int supportedOrientations: {
        if (startingUp) {
            // Ensure we don't rotate during start up
            return Qt.PrimaryOrientation;
        } else if (greeter.shown || lockscreen.shown) {
            return Qt.PrimaryOrientation;
        } else if (mainApp) {
            return mainApp.supportedOrientations;
        } else {
            // we just don't care
            return Qt.PortraitOrientation
                 | Qt.LandscapeOrientation
                 | Qt.InvertedPortraitOrientation
                 | Qt.InvertedLandscapeOrientation;
        }
    }

    // For autopilot consumption
    readonly property string focusedApplicationId: ApplicationManager.focusedApplicationId

    // internal props from here onwards
    readonly property var mainApp:
            applicationsDisplayLoader.item ? applicationsDisplayLoader.item.mainApp : null

    // Disable everything so that user can't swipe greeter or launcher until
    // we get first prompt/authenticate, which will re-enable the shell.
    enabled: false

    property real edgeSize: units.gu(2)
    property url defaultBackground: Qt.resolvedUrl(shell.width >= units.gu(60) ? "graphics/tablet_background.jpg" : "graphics/phone_background.jpg")
    property url background: asImageTester.status == Image.Ready ? asImageTester.source
                             : gsImageTester.status == Image.Ready ? gsImageTester.source : defaultBackground
    readonly property real panelHeight: panel.panelHeight

    readonly property bool locked: LightDM.Greeter.active && !LightDM.Greeter.authenticated && !forcedUnlock
    readonly property alias hasLockedApp: greeter.hasLockedApp
    readonly property bool forcedUnlock: edgeDemo.running
    onForcedUnlockChanged: if (forcedUnlock) lockscreen.hide()

    property int maxFailedLogins: -1 // disabled by default for now, will enable via settings in future
    property int failedLoginsDelayAttempts: 7 // number of failed logins
    property int failedLoginsDelayMinutes: 5 // minutes of forced waiting

    function activateApplication(appId) {
        if (ApplicationManager.findApplication(appId)) {
            ApplicationManager.requestFocusApplication(appId);
        } else {
            var execFlags = shell.usageScenario === "phone" ? ApplicationManager.ForceMainStage
                                                            : ApplicationManager.NoFlag;
            ApplicationManager.startApplication(appId, execFlags);
        }
    }

    function startLockedApp(app) {
        if (shell.locked) {
            greeter.lockedApp = app;
        }
        shell.activateApplication(app);
    }

    // This is a dummy image to detect if the custom AS set wallpaper loads successfully.
    Image {
        id: asImageTester
        source: AccountsService.backgroundFile != undefined && AccountsService.backgroundFile.length > 0 ? AccountsService.backgroundFile : ""
        height: 0
        width: 0
        sourceSize.height: 0
        sourceSize.width: 0
    }

    GSettings {
        id: backgroundSettings
        schema.id: "org.gnome.desktop.background"
    }

    // This is a dummy image to detect if the custom GSettings set wallpaper loads successfully.
    Image {
        id: gsImageTester
        source: backgroundSettings.pictureUri != undefined && backgroundSettings.pictureUri.length > 0 ? backgroundSettings.pictureUri : ""
        height: 0
        width: 0
        sourceSize.height: 0
        sourceSize.width: 0
    }

    Binding {
        target: LauncherModel
        property: "applicationManager"
        value: ApplicationManager
    }

    Component.onCompleted: {
        Theme.name = "Ubuntu.Components.Themes.SuruGradient"
        if (ApplicationManager.count > 0) {
            ApplicationManager.focusApplication(ApplicationManager.get(0).appId);
        }
        finishStartUpTimer.start();
    }

    VolumeControl {
        id: volumeControl
    }

    DashCommunicator {
        id: dash
        objectName: "dashCommunicator"
    }

    ScreenGrabber {
        id: screenGrabber
        z: edgeDemo.z + 10
        enabled: Powerd.status === Powerd.On
    }

    Binding {
        target: ApplicationManager
        property: "forceDashActive"
        value: launcher.shown || launcher.dashSwipe
    }

    VolumeKeyFilter {
        id: volumeKeyFilter
        onVolumeDownPressed: volumeControl.volumeDown()
        onVolumeUpPressed: volumeControl.volumeUp()
        onBothVolumeKeysPressed: screenGrabber.capture()
    }

    WindowKeysFilter {
        Keys.onPressed: {
            // Nokia earpieces give TogglePlayPause, while the iPhone's earpiece gives Play
            if (event.key == Qt.Key_MediaTogglePlayPause || event.key == Qt.Key_MediaPlay) {
                event.accepted = callManager.handleMediaKey(false);
            } else if (event.key == Qt.Key_PowerOff || event.key == Qt.Key_PowerDown) {
                // FIXME: We only consider power key presses if the screen is
                // on because of bugs 1410830/1409003.  The theory is that when
                // those bugs are encountered, there is a >2s delay between the
                // power press event and the power release event, which causes
                // the shutdown dialog to appear on resume.  So to avoid that
                // symptom while we investigate the root cause, we simply won't
                // initiate any dialogs when the screen is off.
                if (Powerd.status === Powerd.On) {
                    dialogs.onPowerKeyPressed();
                }
                event.accepted = true;
            } else {
                volumeKeyFilter.onKeyPressed(event.key);
                event.accepted = false;
            }
        }

        Keys.onReleased: {
            if (event.key == Qt.Key_PowerOff || event.key == Qt.Key_PowerDown) {
                dialogs.onPowerKeyReleased();
                event.accepted = true;
            } else {
                volumeKeyFilter.onKeyReleased(event.key);
                event.accepted = false;
            }
        }
    }

    Item {
        id: stages
        objectName: "stages"
        width: parent.width
        height: parent.height
        visible: !ApplicationManager.empty

        Connections {
            target: ApplicationManager
            onFocusRequested: {
                if (greeter.narrowMode) {
                    if (appId === "dialer-app" && callManager.hasCalls && shell.locked) {
                        // If we are in the middle of a call, make dialer lockedApp and show it.
                        // This can happen if user backs out of dialer back to greeter, then
                        // launches dialer again.
                        greeter.lockedApp = appId;
                    }
                    if (greeter.hasLockedApp) {
                        if (appId === greeter.lockedApp) {
                            lockscreen.hide() // show locked app
                        } else {
                            greeter.startUnlock() // show lockscreen if necessary
                        }
                    }
                    greeter.hide();
                } else {
                    if (LightDM.Greeter.active) {
                        greeter.startUnlock()
                    }
                }
            }

            onFocusedApplicationIdChanged: {
                if (greeter.hasLockedApp && greeter.lockedApp !== ApplicationManager.focusedApplicationId) {
                    greeter.startUnlock()
                }
                panel.indicators.hide();
            }

            onApplicationAdded: {
                if (greeter.shown && appId != "unity8-dash") {
                    greeter.startUnlock()

                    // If this happens on first boot, we may be in edge
                    // tutorial or wizard while receiving a call.  But a call
                    // is more important than wizard so just bail out of those.
                    if (edgeDemo.running) {
                        edgeDemo.hideEdgeDemos();
                        wizard.hide();
                    }
                }
                if (greeter.narrowMode && greeter.hasLockedApp && appId === greeter.lockedApp) {
                    lockscreen.hide() // show locked app
                }
                launcher.hide();
            }
        }

        Loader {
            id: applicationsDisplayLoader
            objectName: "applicationsDisplayLoader"
            anchors.fill: parent

            // When we have a locked app, we only want to show that one app.
            // FIXME: do this in a less traumatic way.  We currently only allow
            // locked apps in phone mode (see FIXME in Lockscreen component in
            // this same file).  When that changes, we need to do something
            // nicer here.  But this code is currently just to prevent a
            // theoretical attack where user enters lockedApp mode, then makes
            // the screen larger (maybe connects to monitor) and tries to enter
            // tablet mode.

            property string usageScenario: shell.usageScenario === "phone" || greeter.hasLockedApp
                                           ? "phone"
                                           : shell.usageScenario
            source: {
                if (applicationsDisplayLoader.usageScenario === "phone") {
                    return "Stages/PhoneStage.qml";
                } else if (applicationsDisplayLoader.usageScenario === "tablet") {
                    return "Stages/TabletStage.qml";
                } else {
                    return "Stages/DesktopStage.qml";
                }
            }

            property bool interactive: edgeDemo.stagesEnabled
                    && !greeter.shown
                    && !lockscreen.shown
                    && panel.indicators.fullyClosed
                    && launcher.progress == 0
                    && !notifications.useModal
            onInteractiveChanged: { if (interactive) { focus = true; } }

            Binding {
                target: applicationsDisplayLoader.item
                property: "objectName"
                value: "stage"
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "dragAreaWidth"
                value: shell.edgeSize
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "maximizedAppTopMargin"
                // Not just using panel.panelHeight as that changes depending on the focused app.
                value: panel.indicators.minimizedPanelHeight + units.dp(2) // dp(2) for orange line
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "interactive"
                value: applicationsDisplayLoader.interactive
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "spreadEnabled"
                value: edgeDemo.stagesEnabled && !greeter.hasLockedApp
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "inverseProgress"
                value: launcher.progress
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "shellOrientationAngle"
                value: shell.orientationAngle
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "shellOrientation"
                value: shell.orientation
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "background"
                value: shell.background
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "shellPrimaryOrientation"
                value: shell.primaryOrientation
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "nativeOrientation"
                value: shell.nativeOrientation
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "nativeWidth"
                value: shell.nativeWidth
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "nativeHeight"
                value: shell.nativeHeight
            }
            Binding {
                target: applicationsDisplayLoader.item
                property: "beingResized"
                value: shell.beingResized
            }
        }
    }

    InputMethod {
        id: inputMethod
        objectName: "inputMethod"
        anchors { fill: parent; topMargin: panel.panelHeight }
        z: notifications.useModal || panel.indicators.shown || wizard.active ? overlay.z + 1 : overlay.z - 1
    }

    Connections {
        target: SurfaceManager
        onSurfaceCreated: {
            if (surface.type == MirSurfaceItem.InputMethod) {
                inputMethod.surface = surface;
            }
        }

        onSurfaceDestroyed: {
            if (inputMethod.surface == surface) {
                inputMethod.surface = null;
                surface.parent = null;
            }
            if (!surface.parent) {
                // there's no one displaying it. delete it right away
                surface.release();
            }
        }
    }
    Connections {
        target: SessionManager
        onSessionStopping: {
            if (!session.parentSession && !session.application) {
                // nothing is using it. delete it right away
                session.release();
            }
        }
    }

    Lockscreen {
        id: lockscreen
        objectName: "lockscreen"

        hides: [launcher, panel.indicators]
        shown: false
        enabled: true
        showAnimation: StandardAnimation { property: "opacity"; to: 1 }
        hideAnimation: StandardAnimation { property: "opacity"; to: 0 }
        y: panel.panelHeight
        visible: required
        width: parent.width
        height: parent.height - panel.panelHeight
        background: shell.background
        darkenBackground: 0.4
        alphaNumeric: AccountsService.passwordDisplayHint === AccountsService.Keyboard
        minPinLength: 4
        maxPinLength: 4

        property string promptText
        infoText: promptText !== "" ? i18n.tr("Enter %1").arg(promptText) :
                  alphaNumeric ? i18n.tr("Enter passphrase") :
                                 i18n.tr("Enter passcode")
        errorText: promptText !== "" ? i18n.tr("Sorry, incorrect %1").arg(promptText) :
                   alphaNumeric ? i18n.tr("Sorry, incorrect passphrase") + "\n" +
                                  i18n.tr("Please re-enter") :
                                  i18n.tr("Sorry, incorrect passcode")

        // FIXME: We *should* show emergency dialer if there is a SIM present,
        // regardless of whether the side stage is enabled.  But right now,
        // the assumption is that narrow screens are phones which have SIMs
        // and wider screens are tablets which don't.  When we do allow this
        // on devices with a side stage and a SIM, work should be done to
        // ensure that the main stage is disabled while the dialer is present
        // in the side stage.  See the FIXME in the stage loader in this file.
        showEmergencyCallButton: shell.usageScenario === "phone"

        onEntered: LightDM.Greeter.respond(passphrase);
        onCancel: greeter.show()
        onEmergencyCall: startLockedApp("dialer-app")

        onShownChanged: if (shown) greeter.lockedApp = ""

        function maybeShow() {
            if (!shell.forcedUnlock) {
                showNow();
            }
        }

        Timer {
            id: forcedDelayTimer
            interval: 1000 * 60
            onTriggered: {
                if (lockscreen.delayMinutes > 0) {
                    lockscreen.delayMinutes -= 1
                    if (lockscreen.delayMinutes > 0) {
                        start() // go again
                    }
                }
            }
        }

        Component.onCompleted: {
            if (greeter.narrowMode) {
                LightDM.Greeter.authenticate(LightDM.Users.data(0, LightDM.UserRoles.NameRole))
            }
        }
    }

    Connections {
        target: LightDM.Greeter

        onShowGreeter: greeter.show()
        onHideGreeter: greeter.login()

        onShowPrompt: {
            shell.enabled = true;
            if (!LightDM.Greeter.active) {
                return; // could happen if hideGreeter() comes in before we prompt
            }
            if (greeter.narrowMode) {
                lockscreen.promptText = isDefaultPrompt ? "" : text.toLowerCase();
                lockscreen.maybeShow();
            }
        }

        onPromptlessChanged: {
            if (!LightDM.Greeter.active) {
                return; // could happen if hideGreeter() comes in before we prompt
            }
            if (greeter.narrowMode) {
                if (LightDM.Greeter.promptless && LightDM.Greeter.authenticated) {
                    lockscreen.hide()
                } else {
                    lockscreen.reset();
                    lockscreen.maybeShow();
                }
            }
        }

        onAuthenticationComplete: {
            shell.enabled = true;
            if (LightDM.Greeter.authenticated) {
                AccountsService.failedLogins = 0
            }
            // Else only penalize user for a failed login if they actually were
            // prompted for a password.  We do this below after the promptless
            // early exit.

            if (LightDM.Greeter.promptless) {
                return;
            }

            if (LightDM.Greeter.authenticated) {
                greeter.login();
            } else {
                AccountsService.failedLogins++
                if (maxFailedLogins >= 2) { // require at least a warning
                    if (AccountsService.failedLogins === maxFailedLogins - 1) {
                        var title = lockscreen.alphaNumeric ?
                                    i18n.tr("Sorry, incorrect passphrase.") :
                                    i18n.tr("Sorry, incorrect passcode.")
                        var text = i18n.tr("This will be your last attempt.") + " " +
                                   (lockscreen.alphaNumeric ?
                                    i18n.tr("If passphrase is entered incorrectly, your phone will conduct a factory reset and all personal data will be deleted.") :
                                    i18n.tr("If passcode is entered incorrectly, your phone will conduct a factory reset and all personal data will be deleted."))
                        lockscreen.showInfoPopup(title, text)
                    } else if (AccountsService.failedLogins >= maxFailedLogins) {
                        SystemImage.factoryReset() // Ouch!
                    }
                }
                if (failedLoginsDelayAttempts > 0 && AccountsService.failedLogins % failedLoginsDelayAttempts == 0) {
                    lockscreen.delayMinutes = failedLoginsDelayMinutes
                    forcedDelayTimer.start()
                }

                lockscreen.clear(true);
                if (greeter.narrowMode) {
                    LightDM.Greeter.authenticate(LightDM.Users.data(0, LightDM.UserRoles.NameRole))
                }
            }
        }
    }

    Binding {
        target: LightDM.Greeter
        property: "active"
        value: greeter.shown || lockscreen.shown || greeter.hasLockedApp
    }

    Rectangle {
        anchors.fill: parent
        color: "black"
        opacity: greeterWrapper.showProgress * 0.8
    }

    Item {
        // Just a tiny wrapper to adjust greeter's x without messing with its own dragging
        id: greeterWrapper
        objectName: "greeterWrapper"
        x: (greeter.narrowMode && greeter.showProgress > 0) ? launcher.progress : 0
        y: panel.panelHeight
        width: parent.width
        height: parent.height - panel.panelHeight

        Behavior on x {
            enabled: !launcher.dashSwipe
            StandardAnimation {}
        }

        property bool fullyShown: showProgress === 1.0
        onFullyShownChanged: {
            // Wait until the greeter is completely covering lockscreen before resetting it.
            if (greeter.narrowMode && fullyShown && !LightDM.Greeter.authenticated) {
                lockscreen.reset();
                lockscreen.maybeShow();
            }
        }

        readonly property real showProgress: MathUtils.clamp((1 - x/width) + greeter.showProgress - 1, 0, 1)
        onShowProgressChanged: {
            if (showProgress === 0) {
                if ((LightDM.Greeter.promptless && LightDM.Greeter.authenticated) || shell.forcedUnlock) {
                    greeter.login()
                } else if (greeter.narrowMode) {
                    lockscreen.clear(false) // to reset focus if necessary
                }
            }
        }

        Greeter {
            id: greeter
            objectName: "greeter"

            signal sessionStarted() // helpful for tests

            property string lockedApp: ""
            property bool hasLockedApp: lockedApp !== ""

            hides: [launcher, panel.indicators]
            loadContent: required || lockscreen.required // keeps content in memory for quick show()

            locked: shell.locked

            background: shell.background

            width: parent.width
            height: parent.height

            // avoid overlapping with Launcher's edge drag area
            // FIXME: Fix TouchRegistry & friends and remove this workaround
            //        Issue involves launcher's DDA getting disabled on a long
            //        left-edge drag
            dragHandleLeftMargin: launcher.available ? launcher.dragAreaWidth + 1 : 0

            function startUnlock() {
                if (narrowMode) {
                    if (!LightDM.Greeter.authenticated) {
                        lockscreen.maybeShow()
                    }
                    hide()
                } else {
                    show()
                    tryToUnlock()
                }
            }

            function login() {
                enabled = false;
                if (LightDM.Greeter.startSessionSync()) {
                    sessionStarted();
                    greeter.hide();
                    lockscreen.hide();
                    launcher.hide();
                }
                enabled = true;
            }

            Timer {
                // See powerConnection for why this is useful
                id: showGreeterDelayed
                interval: 1
                onTriggered: {
                    greeter.showNow();
                }
            }

            onShownChanged: {
                if (shown) {
                    // Disable everything so that user can't swipe greeter or
                    // launcher until we get the next prompt/authenticate, which
                    // will re-enable the shell.
                    shell.enabled = false;

                    if (greeter.narrowMode) {
                        LightDM.Greeter.authenticate(LightDM.Users.data(0, LightDM.UserRoles.NameRole));
                    } else {
                        reset()
                    }
                    greeter.lockedApp = "";
                    greeter.forceActiveFocus();
                }
            }

            Component.onCompleted: {
                Connectivity.unlockAllModems()
            }

            onUnlocked: greeter.hide()
            onSelected: {
                // Update launcher items for new user
                var user = LightDM.Users.data(uid, LightDM.UserRoles.NameRole);
                AccountsService.user = user;
                LauncherModel.setUser(user);
            }

            onTapped: launcher.tease()
            onDraggingChanged: {
                if (dragging) {
                    launcher.tease();
                }
            }

            Binding {
                target: ApplicationManager
                property: "suspended"
                value: (greeter.shown && greeterWrapper.showProgress == 1) || lockscreen.shown
            }
        }
    }

    Connections {
        id: callConnection
        target: callManager

        onHasCallsChanged: {
            if (shell.locked && callManager.hasCalls && greeter.lockedApp !== "dialer-app") {
                // We just received an incoming call while locked.  The
                // indicator will have already launched dialer-app for us, but
                // there is a race between "hasCalls" changing and the dialer
                // starting up.  So in case we lose that race, we'll start/
                // focus the dialer ourselves here too.  Even if the indicator
                // didn't launch the dialer for some reason (or maybe a call
                // started via some other means), if an active call is
                // happening, we want to be in the dialer.
                startLockedApp("dialer-app")
            }
        }
    }

    Connections {
        id: powerConnection
        target: Powerd

        onStatusChanged: {
            if (Powerd.status === Powerd.Off && reason !== Powerd.Proximity &&
                    !callManager.hasCalls && !edgeDemo.running) {
                // We don't want to simply call greeter.showNow() here, because
                // that will take too long.  Qt will delay button event
                // handling until the greeter is done loading and may think the
                // user held down the power button the whole time, leading to a
                // power dialog being shown.  Instead, delay showing the
                // greeter until we've finished handling the event.  We could
                // make the greeter load asynchronously instead, but that
                // introduces a whole host of timing issues, especially with
                // its animations.  So this is simpler.
                showGreeterDelayed.start();
            }
        }
    }

    function showHome() {
        if (edgeDemo.running) {
            return
        }

        if (LightDM.Greeter.active) {
            greeter.startUnlock()
        }

        var animate = !LightDM.Greeter.active && !stages.shown
        dash.setCurrentScope(0, animate, false)
        ApplicationManager.requestFocusApplication("unity8-dash")
    }

    function showDash() {
        if (greeter.hasLockedApp || // just in case user gets here
            (!greeter.narrowMode && shell.locked)) {
            return
        }

        if (greeter.shown) {
            greeter.hideRight();
            launcher.fadeOut();
        }

        if (ApplicationManager.focusedApplicationId != "unity8-dash") {
            ApplicationManager.requestFocusApplication("unity8-dash")
            launcher.fadeOut();
        }
    }

    Item {
        id: overlay
        z: 10

        anchors.fill: parent

        Panel {
            id: panel
            objectName: "panel"
            anchors.fill: parent //because this draws indicator menus
            indicators {
                hides: [launcher]
                available: edgeDemo.panelEnabled && (!shell.locked || AccountsService.enableIndicatorsWhileLocked) && !greeter.hasLockedApp
                contentEnabled: edgeDemo.panelContentEnabled
                width: parent.width > units.gu(60) ? units.gu(40) : parent.width

                minimizedPanelHeight: units.gu(3)
                expandedPanelHeight: units.gu(7)

                indicatorsModel: visibleIndicators.model
            }

            VisibleIndicators {
                id: visibleIndicators
                // tablet and phone both use the same profile
                property string indicatorProfile: shell.usageScenario === "desktop" ? "desktop" : "phone"
                Component.onCompleted: initialise(indicatorProfile)
            }
            callHint {
                greeterShown: greeter.shown || lockscreen.shown
            }

            property bool mainAppIsFullscreen: shell.mainApp && shell.mainApp.fullscreen
            fullscreenMode: (mainAppIsFullscreen && !LightDM.Greeter.active && launcher.progress == 0)
                            || greeter.hasLockedApp
        }

        Launcher {
            id: launcher
            objectName: "launcher"

            readonly property bool dashSwipe: progress > 0

            anchors.top: parent.top
            anchors.topMargin: inverted ? 0 : panel.panelHeight
            anchors.bottom: parent.bottom
            width: parent.width
            dragAreaWidth: shell.edgeSize
            available: edgeDemo.launcherEnabled && (!shell.locked || AccountsService.enableLauncherWhileLocked) && !greeter.hasLockedApp
            inverted: shell.usageScenario !== "desktop"

            onShowDashHome: showHome()
            onDash: showDash()
            onDashSwipeChanged: {
                if (dashSwipe) {
                    dash.setCurrentScope(0, false, true)
                }
            }
            onLauncherApplicationSelected: {
                if (greeter.hasLockedApp) {
                    greeter.startUnlock()
                }
                if (!edgeDemo.running)
                    shell.activateApplication(appId)
            }
            onShownChanged: {
                if (shown) {
                    panel.indicators.hide()
                }
            }
        }

        Wizard {
            id: wizard
            anchors.fill: parent
            background: shell.background
        }

        Rectangle {
            id: modalNotificationBackground

            visible: notifications.useModal
            color: "#000000"
            anchors.fill: parent
            opacity: 0.9

            MouseArea {
                anchors.fill: parent
            }
        }

        Notifications {
            id: notifications

            model: NotificationBackend.Model
            margin: units.gu(1)

            y: topmostIsFullscreen ? 0 : panel.panelHeight
            height: parent.height - (topmostIsFullscreen ? 0 : panel.panelHeight)

            states: [
                State {
                    name: "narrow"
                    when: overlay.width <= units.gu(60)
                    AnchorChanges {
                        target: notifications
                        anchors.left: parent.left
                        anchors.right: parent.right
                    }
                },
                State {
                    name: "wide"
                    when: overlay.width > units.gu(60)
                    AnchorChanges {
                        target: notifications
                        anchors.left: undefined
                        anchors.right: parent.right
                    }
                    PropertyChanges { target: notifications; width: units.gu(38) }
                }
            ]
        }
    }

    Dialogs {
        id: dialogs
        objectName: "dialogs"
        anchors.fill: parent
        z: overlay.z + 10
        onPowerOffClicked: {
            shutdownFadeOutRectangle.enabled = true;
            shutdownFadeOutRectangle.visible = true;
            shutdownFadeOut.start();
        }
    }

    EdgeDemo {
        id: edgeDemo
        objectName: "edgeDemo"
        z: dialogs.z + 10
        paused: Powerd.status === Powerd.Off || wizard.active // Saves power
        greeter: greeter
        launcher: launcher
        panel: panel
        stages: stages
    }

    Connections {
        target: SessionBroadcast
        onShowHome: showHome()
    }

    Rectangle {
        id: shutdownFadeOutRectangle
        z: edgeDemo.z + 10
        enabled: false
        visible: false
        color: "black"
        anchors.fill: parent
        opacity: 0.0
        NumberAnimation on opacity {
            id: shutdownFadeOut
            from: 0.0
            to: 1.0
            onStopped: {
                if (shutdownFadeOutRectangle.enabled && shutdownFadeOutRectangle.visible) {
                    DBusUnitySessionService.Shutdown();
                }
            }
        }
    }

}
