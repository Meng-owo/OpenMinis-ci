import io, sys

P = '/var/minis/workspace/om-r8/src/ios/Minis.xcodeproj/project.pbxproj'
src = io.open(P, encoding='utf-8').read()

FILES = [
    ('E5TG0001', 'E5TG0011', 'TogetherState.swift', 'Agent/Together/TogetherState.swift'),
    ('E5TG0002', 'E5TG0012', 'TogetherStore.swift', 'Agent/Together/TogetherStore.swift'),
    ('E5TG0003', 'E5TG0013', 'TogetherPlayer.swift', 'Agent/Together/TogetherPlayer.swift'),
    ('E5TG0006', 'E5TG0016', 'FakefsBridge.swift', 'Agent/Together/FakefsBridge.swift'),
    ('E5TG0007', 'E5TG0017', 'TogetherSkin.swift', 'Views/Together/TogetherSkin.swift'),
    ('E5TG0008', 'E5TG0018', 'TogetherRootView.swift', 'Views/Together/TogetherRootView.swift'),
    ('E5TG0009', 'E5TG0019', 'TogetherScreens.swift', 'Views/Together/TogetherScreens.swift'),
    ('E5TG000A', 'E5TG001A', 'TogetherImporter.swift', 'Agent/Together/TogetherImporter.swift'),
    ('E5TG0004', 'E5TG0014', 'TogetherPanelView.swift', 'Views/Together/TogetherPanelView.swift'),
    ('E5TG0005', 'E5TG0015', 'TogetherMiniBar.swift', 'Views/Together/TogetherMiniBar.swift'),
]

anchor_build = "\t\tE5PPR0001 /* AIChatViewModel+ProgrammaticPrompt.swift in Sources */ = {isa = PBXBuildFile; fileRef = E5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */; };\n"
anchor_ref = '\t\tE5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "AIChatViewModel+ProgrammaticPrompt.swift"; path = "Agent/Chat/AIChatViewModel+ProgrammaticPrompt.swift"; sourceTree = SOURCE_ROOT; };\n'
anchor_group = "\t\t\t\tE5PPR0011 /* AIChatViewModel+ProgrammaticPrompt.swift */,\n"
anchor_phase = "\t\t\t\tE5PPR0001 /* AIChatViewModel+ProgrammaticPrompt.swift in Sources */,\n"

pending = [f for f in FILES if f[2] not in src]
if not pending:
    print('already registered')
    sys.exit(0)

for a in (anchor_build, anchor_ref, anchor_group, anchor_phase):
    if src.count(a) != 1:
        print('ANCHOR PROBLEM count=%d for %s' % (src.count(a), a[:70]))
        sys.exit(1)

add_build = ''
add_ref = ''
add_group = ''
add_phase = ''

for BID, FID, NAME, REL in pending:
    if FID in src or BID in src:
        print('ID collision: %s / %s' % (BID, FID))
        sys.exit(1)
    add_build += "\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };\n" % (BID, NAME, FID, NAME)
    add_ref += '\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; name = "%s"; path = "%s"; sourceTree = SOURCE_ROOT; };\n' % (FID, NAME, NAME, REL)
    add_group += "\t\t\t\t%s /* %s */,\n" % (FID, NAME)
    add_phase += "\t\t\t\t%s /* %s in Sources */,\n" % (BID, NAME)

src = src.replace(anchor_build, anchor_build + add_build, 1)
src = src.replace(anchor_ref, anchor_ref + add_ref, 1)
src = src.replace(anchor_group, anchor_group + add_group, 1)
src = src.replace(anchor_phase, anchor_phase + add_phase, 1)

io.open(P, 'w', encoding='utf-8').write(src)
print('registered:', ', '.join(f[2] for f in pending))