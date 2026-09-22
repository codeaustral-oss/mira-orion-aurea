#!/usr/bin/env python3
"""
Generate Mira.xcodeproj from the source tree.

The project is generated rather than hand-maintained, because the two apps share
one folder of sources and three targets reference overlapping sets. Doing that by
hand means every new file needs editing in several places, and a mistake there
produces a project that opens but silently compiles nothing.

Deterministic: same tree in, same project out. Re-run after adding files.

  ./scripts/make-xcodeproj.py

Targets
  MiraOrion   Mira/ + Orion/
  MiraAurea   Mira/ + Aurea/
  MiraTests   MiraTests/
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "MiraApp"
PROJ = APP / "Mira.xcodeproj"

_counter = [0x1000]


def oid() -> str:
    """A fresh 24-character uppercase hex object id."""
    _counter[0] += 1
    return f"{_counter[0]:024X}"


def fixed(n: str) -> str:
    s = n.upper()
    assert all(c in "0123456789ABCDEF" for c in s), n
    return s.rjust(24, "0")


def swift(folder: str) -> list[Path]:
    base = APP / folder
    if not base.exists():
        return []
    return sorted(p for p in base.rglob("*.swift"))


# --------------------------------------------------------------------------- #
# Sources
# --------------------------------------------------------------------------- #

SHARED = swift("Mira")
ORION = swift("Orion")
AUREA = swift("Aurea")
TESTS = swift("MiraTests")
ASSET_CATALOG = APP / "Mira" / "Resources" / "Assets.xcassets"
BRAND_CATALOGS = {"orion": APP / "Orion" / "Assets.xcassets", "aurea": APP / "Aurea" / "Assets.xcassets"}

if not SHARED:
    sys.exit("no shared sources found; is Mira/ in place?")

file_id = {p: oid() for p in SHARED + ORION + AUREA + TESTS}
assets_id = oid()

build_id: dict[tuple[Path, str], str] = {}


def build(p: Path, target: str) -> str:
    key = (p, target)
    if key not in build_id:
        build_id[key] = oid()
    return build_id[key]


# --------------------------------------------------------------------------- #
# Groups, mirroring the folders so relative paths resolve
# --------------------------------------------------------------------------- #

groups: list[str] = []
group_id: dict[Path, str] = {}


def make_tree(root: Path, files: list[Path], extra_child: str | None = None) -> str:
    if not root.exists():
        return ""

    dirs = {root}
    for f in files:
        d = f.parent
        while d == root or root in d.parents:
            dirs.add(d)
            if d == root:
                break
            d = d.parent

    def emit(d: Path) -> str:
        gid = group_id.setdefault(d, oid())
        children = []
        if extra_child and d == ASSET_CATALOG.parent:
            children.append(f"\t\t\t\t{extra_child} /* Assets.xcassets */,")
        children += [f"\t\t\t\t{file_id[f]} /* {f.name} */," for f in sorted(files) if f.parent == d]
        children += [f"\t\t\t\t{emit(c)} /* {c.name} */," for c in sorted(dirs) if c.is_dir() and c != d and c.parent == d]
        name = d.name
        groups.append(f"""\t\t{gid} /* {name} */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(children)}
\t\t\t);
\t\t\tpath = {name};
\t\t\tsourceTree = "<group>";
\t\t}};""")
        return gid

    return emit(root)


mira_root = make_tree(APP / "Mira", SHARED, assets_id)
orion_root = make_tree(APP / "Orion", ORION)
aurea_root = make_tree(APP / "Aurea", AUREA)
tests_root = make_tree(APP / "MiraTests", TESTS)

products_g = oid()
root_g = oid()

# --------------------------------------------------------------------------- #
# Fixed structural ids
# --------------------------------------------------------------------------- #

T_ORION = fixed("5")
T_AUREA = fixed("32")
T_TESTS = fixed("53")
F_ORION = fixed("4")
F_AUREA = fixed("31")
F_TESTS = fixed("7")
P_PROJ = fixed("6")
CL_PROJ, CL_ORION, CL_AUREA, CL_TESTS = fixed("A"), fixed("B"), fixed("3B"), fixed("5B")
CFG_PD, CFG_PR = fixed("C"), fixed("D")
CFG_OD, CFG_OR = fixed("E"), fixed("F")
CFG_AD, CFG_AR = fixed("3E"), fixed("3F")
CFG_TD, CFG_TR = fixed("5E"), fixed("5F")
PH_OS, PH_OF, PH_OR = fixed("11"), fixed("12"), fixed("13")
PH_AS, PH_AF, PH_AR = fixed("41"), fixed("42"), fixed("43")
PH_TS, PH_TF, PH_TR = fixed("61"), fixed("62"), fixed("63")
PROXY, DEP = fixed("71"), fixed("72")

assets_build = {t: oid() for t in ("orion", "aurea")}
brand_assets_id = {t: oid() for t in ("orion", "aurea")}
brand_assets_build = {t: oid() for t in ("orion", "aurea")}

# --------------------------------------------------------------------------- #
# Emit
# --------------------------------------------------------------------------- #

file_refs = "\n".join(
    f'\t\t{file_id[p]} /* {p.name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {p.name}; sourceTree = "<group>"; }};'
    for p in SHARED + ORION + AUREA + TESTS
)
file_refs += (
    f'\n\t\t{assets_id} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; '
    f'name = Assets.xcassets; path = Mira/Resources/Assets.xcassets; sourceTree = SOURCE_ROOT; }};'
)
for t, path in BRAND_CATALOGS.items():
    file_refs += (
        f'\n\t\t{brand_assets_id[t]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; '
        f'name = Assets.xcassets; path = {path.relative_to(APP)}; sourceTree = SOURCE_ROOT; }};'
    )

build_files = []
for p in SHARED:
    build_files.append(f'\t\t{build(p, "orion")} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id[p]} /* {p.name} */; }};')
    build_files.append(f'\t\t{build(p, "aurea")} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id[p]} /* {p.name} */; }};')
for p in ORION:
    build_files.append(f'\t\t{build(p, "orion")} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id[p]} /* {p.name} */; }};')
for p in AUREA:
    build_files.append(f'\t\t{build(p, "aurea")} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id[p]} /* {p.name} */; }};')
for p in TESTS:
    build_files.append(f'\t\t{build(p, "tests")} /* {p.name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_id[p]} /* {p.name} */; }};')
for t in ("orion", "aurea"):
    build_files.append(f'\t\t{assets_build[t]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_id} /* Assets.xcassets */; }};')
    build_files.append(f'\t\t{brand_assets_build[t]} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {brand_assets_id[t]} /* Assets.xcassets */; }};')


def src_list(files: list[Path], target: str) -> str:
    return "\n".join(f"\t\t\t\t{build(p, target)} /* {p.name} in Sources */," for p in files)


groups_block = "\n".join(groups) + f"""
\t\t{products_g} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{F_ORION} /* MiraOrion.app */,
\t\t\t\t{F_AUREA} /* MiraAurea.app */,
\t\t\t\t{F_TESTS} /* MiraTests.xctest */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{root_g} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{mira_root} /* Mira */,
\t\t\t\t{orion_root} /* Orion */,
\t\t\t\t{aurea_root} /* Aurea */,
\t\t\t\t{tests_root} /* MiraTests */,
\t\t\t\t{products_g} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};"""


def app_settings(display: str, bundle: str, module: str) -> str:
    return f"""\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = Supporting/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.3;
\t\t\t\tMIRA_DISPLAY_NAME = "{display}";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {bundle};
\t\t\t\tPRODUCT_MODULE_NAME = {module};
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_STRICT_CONCURRENCY = targeted;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";"""


test_settings = f"""\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMARKETING_VERSION = 0.3;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.codeaustral.mira.tests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_STRICT_CONCURRENCY = targeted;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/MiraOrion.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MiraOrion";"""

debug_proj = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (
\t\t\t\t\t"DEBUG=1",
\t\t\t\t\t"$(inherited)",
\t\t\t\t);
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";"""

release_proj = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 18.0;
\t\t\t\tMTL_FAST_MATH = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tVALIDATE_PRODUCT = YES;"""


def config(cid: str, name: str, settings: str) -> str:
    return f"\t\t{cid} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{settings}\n\t\t\t}};\n\t\t\tname = {name};\n\t\t}};"


def target(name: str, tid: str, phases: tuple[str, str, str], cl: str, product: str, ptype: str, deps: str) -> str:
    sources, frameworks, resources = phases
    return f"""\t\t{tid} /* {name} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cl} /* Build configuration list for PBXNativeTarget "{name}" */;
\t\t\tbuildPhases = (
\t\t\t\t{sources} /* Sources */,
\t\t\t\t{frameworks} /* Frameworks */,
\t\t\t\t{resources} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
{deps}
\t\t\t);
\t\t\tname = {name};
\t\t\tproductName = {name};
\t\t\tproductReference = {product};
\t\t\tproductType = "{ptype}";
\t\t}};"""


project = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
\t\t{PROXY} /* PBXContainerItemProxy */ = {{
\t\t\tisa = PBXContainerItemProxy;
\t\t\tcontainerPortal = {P_PROJ} /* Project object */;
\t\t\tproxyType = 1;
\t\t\tremoteGlobalIDString = {T_ORION};
\t\t\tremoteInfo = MiraOrion;
\t\t}};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
\t\t{F_ORION} /* MiraOrion.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MiraOrion.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{F_AUREA} /* MiraAurea.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = MiraAurea.app; sourceTree = BUILT_PRODUCTS_DIR; }};
\t\t{F_TESTS} /* MiraTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MiraTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};
{file_refs}
/* End PBXFileReference section */

/* Begin PBXGroup section */
{groups_block}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{target("MiraOrion", T_ORION, (PH_OS, PH_OF, PH_OR), CL_ORION, f"{F_ORION} /* MiraOrion.app */", "com.apple.product-type.application", "")}
{target("MiraAurea", T_AUREA, (PH_AS, PH_AF, PH_AR), CL_AUREA, f"{F_AUREA} /* MiraAurea.app */", "com.apple.product-type.application", "")}
{target("MiraTests", T_TESTS, (PH_TS, PH_TF, PH_TR), CL_TESTS, f"{F_TESTS} /* MiraTests.xctest */", "com.apple.product-type.bundle.unit-test", f"\t\t\t\t{DEP} /* PBXTargetDependency */,")}
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{P_PROJ} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2650;
\t\t\t\tLastUpgradeCheck = 2650;
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{T_ORION} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;
\t\t\t\t\t}};
\t\t\t\t\t{T_AUREA} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;
\t\t\t\t\t}};
\t\t\t\t\t{T_TESTS} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 26.5;
\t\t\t\t\t\tTestTargetID = {T_ORION};
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {CL_PROJ} /* Build configuration list for PBXProject "Mira" */;
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {root_g};
\t\t\tproductRefGroup = {products_g} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{T_ORION} /* MiraOrion */,
\t\t\t\t{T_AUREA} /* MiraAurea */,
\t\t\t\t{T_TESTS} /* MiraTests */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{PH_OR} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_build['orion']} /* Assets.xcassets in Resources */,\n\t\t\t\t{brand_assets_build['orion']} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_AR} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t\t{assets_build['aurea']} /* Assets.xcassets in Resources */,\n\t\t\t\t{brand_assets_build['aurea']} /* Assets.xcassets in Resources */,
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_TR} /* Resources */ = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{PH_OF} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_AF} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_TF} /* Frameworks */ = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{PH_OS} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{src_list(SHARED, "orion")}
{src_list(ORION, "orion")}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_AS} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{src_list(SHARED, "aurea")}
{src_list(AUREA, "aurea")}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
\t\t{PH_TS} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{src_list(TESTS, "tests")}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
\t\t{DEP} /* PBXTargetDependency */ = {{
\t\t\tisa = PBXTargetDependency;
\t\t\ttarget = {T_ORION} /* MiraOrion */;
\t\t\ttargetProxy = {PROXY} /* PBXContainerItemProxy */;
\t\t}};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
{config(CFG_PD, "Debug", debug_proj)}
{config(CFG_PR, "Release", release_proj)}
{config(CFG_OD, "Debug", app_settings("Mira Orion", "com.codeaustral.mira.orion", "MiraOrion"))}
{config(CFG_OR, "Release", app_settings("Mira Orion", "com.codeaustral.mira.orion", "MiraOrion"))}
{config(CFG_AD, "Debug", app_settings("Mira Aurea", "com.codeaustral.mira.aurea", "MiraAurea"))}
{config(CFG_AR, "Release", app_settings("Mira Aurea", "com.codeaustral.mira.aurea", "MiraAurea"))}
{config(CFG_TD, "Debug", test_settings)}
{config(CFG_TR, "Release", test_settings)}
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{CL_PROJ} /* Build configuration list for PBXProject "Mira" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_PD} /* Debug */,
\t\t\t\t{CFG_PR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CL_ORION} /* Build configuration list for PBXNativeTarget "MiraOrion" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_OD} /* Debug */,
\t\t\t\t{CFG_OR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CL_AUREA} /* Build configuration list for PBXNativeTarget "MiraAurea" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_AD} /* Debug */,
\t\t\t\t{CFG_AR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CL_TESTS} /* Build configuration list for PBXNativeTarget "MiraTests" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{CFG_TD} /* Debug */,
\t\t\t\t{CFG_TR} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {P_PROJ} /* Project object */;
}}
"""

PROJ.mkdir(parents=True, exist_ok=True)
(PROJ / "project.pbxproj").write_text(project)

# Schemes
schemes = PROJ / "xcshareddata" / "xcschemes"
if schemes.exists():
    shutil.rmtree(schemes)
schemes.mkdir(parents=True)


def scheme(name: str, tid: str, product: str, testable: tuple[str, str, str] | None = None) -> str:
    test_block = ""
    if testable:
        test_block = f"""      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{testable[0]}"
               BuildableName = "{testable[1]}"
               BlueprintName = "{testable[2]}"
               ReferencedContainer = "container:Mira.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>"""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2650"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{tid}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:Mira.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
{test_block}
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "{product}"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Mira.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{tid}"
            BuildableName = "{product}"
            BlueprintName = "{name}"
            ReferencedContainer = "container:Mira.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""


(schemes / "MiraOrion.xcscheme").write_text(scheme("MiraOrion", T_ORION, "MiraOrion.app", (T_TESTS, "MiraTests.xctest", "MiraTests")))
(schemes / "MiraAurea.xcscheme").write_text(scheme("MiraAurea", T_AUREA, "MiraAurea.app"))
(schemes / "Mira.xcscheme").write_text(scheme("MiraOrion", T_ORION, "MiraOrion.app", (T_TESTS, "MiraTests.xctest", "MiraTests")))

print(f"Mira.xcodeproj written: {len(SHARED)} shared, {len(ORION)} Orion, {len(AUREA)} Aurea, {len(TESTS)} test sources")
