import io, sys, re

P = '/var/minis/workspace/om-r8/src/ios/Minis.xcodeproj/project.pbxproj'
src = io.open(P, encoding='utf-8').read()

BID = 'E5CBK0002'
FID = 'E5CBK0012'
NAME = 'UserProfileView.swift'
REL = 'Views/Chat/UserProfileView.swift'

if NAME in src:
    print('already registered')
    sys.exit(0)

anchor_build = "\t\tE5PPR0001 /* AIChatViewModel+ProgrammaticPrompt.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */; };\n"
new_build = "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (BID, NAME, FID, NAME)

anchor_ref = '\t\tE5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "AIChatViewModel+ProgrammaticPrompt.swift"; path = "Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift"; sourceTree = SOURCE_ROOT; };\n'
new_ref = '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "%s"; path = "%s"; sourceTree = SOURCE_ROOT; };\n' % (FID, NAME, NAME, REL)

anchor_group = "\t\t\t\tE5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */,\n"
new_group = "\t\t\t\t%s /* %s */,\n" % (FID, NAME)

anchor_phase = "\t\t\t\tE5PPR0001 /* AIChatViewModel+ProgrammaticPrompt.swift in Sources */,\n"
new_phase = "\t\t\t\t%s /* %s in Sources */,\n" % (BID, NAME)

for a in (anchor_build, anchor_ref, anchor_group, anchor_phase):
    if src.count(a) != 1:
        print('ANCHOR PROBLEM count=%d for %s' % (src.count(a), a[:80]))
        sys.exit(1)

src = src.replace(anchor_build, anchor_build + new_build, 1)
src = src.replace(anchor_ref, anchor_ref + new_ref, 1)
src = src.replace(anchor_group, anchor_group + new_group, 1)
src = src.replace(anchor_phase, anchor_phase + new_phase, 1)

io.open(P, 'w', encoding='utf-8').write(src)
print('registered', NAME)
