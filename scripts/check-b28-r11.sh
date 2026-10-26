#!/bin/bash
# [B28 R11] 通讯录里的「我自己」：用户人设，可被 AI 看见、可被 AI 编辑、称呼自适应。
cd "$(dirname "$0")/.." || exit 1
PS=src/ios/Agent/Session/PersonaStore.swift
SS=src/ios/Agent/Session/SoulStore.swift
VM=src/ios/Agent/Chat/AIChatViewModel.swift
AS=src/ios/Shared/AppearanceStudio.swift
CT=src/ios/Views/Chat/PersonaContactsView.swift
UP=src/ios/Views/Chat/UserProfileView.swift
PB=src/ios/Minis.xcodeproj/project.pbxproj
fails=0
chk(){ if eval "$2"; then echo "  ok  $1"; else echo "  FAIL $1"; fails=1; fi; }
chk R11-1 "rg -q 'static let userProfilePersonaID' $PS && rg -q 'static func makeUserProfilePersona' $PS"
chk R11-2 "rg -q 'var isUserProfile: Bool' $PS && rg -q 'forKey: .isUserProfile' $PS"
chk R11-3 "rg -q 'var chatSelectablePersonas' $PS && rg -q 'func isUserProfileID' $PS"
chk R11-4 "! rg -q 'ForEach\\(store\\.personas\\)' src/ios/Views/Chat/PersonaQuickSwitcher.swift && rg -q 'chatSelectablePersonas' src/ios/Views/Chat/PersonaQuickSwitcher.swift"
chk R11-5 "! rg -q 'ForEach\\(store\\.personas\\)' src/ios/Views/Chat/PersonaListSheet.swift"
chk R11-6 "rg -q 'func userProfileSection' $SS && rg -q '关于正在和你说话的人' $SS"
chk R11-7 "rg -q 'isUserProfileID\\(personaID\\)' $SS"
chk R11-8 "rg -q 'userProfileNSFWInjectionEnabled' $SS"
chk R11-9 "rg -q 'userProfilePromptSection' $VM && rg -q 'SystemPromptBuilder.userProfileSection' $VM"
chk R11-10 "rg -q 'userProfileAddressingName' $AS"
chk R11-11 "rg -q 'func userProfileSection' $SS && rg -q '我的推断' $SS"
chk R11-12 "rg -q 'struct UserProfileView' $UP && rg -q 'UserProfileView()' $CT"
chk R11-13 "rg -q 'UserProfileView.swift' $PB"
chk R11-14 "rg -q 'static func profileSummaryText' $CT && rg -q 'profileSummaryText\\(\\)' $CT"
chk R11-15 "rg -q 'displayName\\(for persona: Persona\\)' $CT || rg -q 'displayName\\(for:' $CT"
chk R11-16 "! rg -q 'SoulStore\\.userProfile' -g '*.swift' src/ios"
chk R11-17 "rg -q 'SystemPromptBuilder\\.userProfile' src/ios/Shared/AppearanceStudio.swift"
chk R13-1 "rg -F -q 'cornerRadius: 22' src/ios/Views/Chat/UserProfileView.swift"
chk R13-2 "rg -q 'presentationDetents' src/ios/Views/Chat/UserProfileView.swift"
chk R13-3 "rg -q 'struct AgentProfileWidget' src/ios/AgentWidget/AgentProfileWidget.swift"
chk R13-4 "rg -q 'AgentProfileWidget()' src/ios/AgentWidget/AgentWidgetBundle.swift"
chk R13-5 "rg -q 'WidgetProfileBridge' src/ios/Agent/Session/PersonaStore.swift"
chk R13-6 "rg -q 'AgentProfileWidget.swift' src/ios/Minis.xcodeproj/project.pbxproj && rg -q 'WidgetProfileBridge.swift' src/ios/Minis.xcodeproj/project.pbxproj"
chk R13-7 "! rg -q 'case avatars|avatarsPage' src/ios/Views/Settings/AppearanceStudioView.swift"
chk R21-1 "rg -q 'func registerExistingMedia' src/ios/Agent/Chat/ChatStore.swift"
chk R21-2 "rg -q 'snapshotMediaRef' src/ios/Agent/Chat/AIChatViewModel+ConcurrentTools.swift"
chk R21-3 "rg -q 'registerExistingMedia' src/ios/Agent/Chat/AIChatViewModel+Persistence.swift"
chk R21-4 "rg -q 'func pruneUnreferencedMedia' src/ios/Agent/Chat/ChatStore.swift"
chk R21-5 "rg -q 'pruneIfDue' src/ios/Agent/Chat/AIChatViewModel+Persistence.swift"
echo "----"
[ $fails -eq 0 ] && echo "全部通过" || exit 1
