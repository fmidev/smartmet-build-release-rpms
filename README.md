# Building SmartMet Server Opendata RPM Packages in Circle-CI Environment
PERL script **smartbuild** (part of package smartmet-utils-devel) is being used for missing RPM packages (version and/or revision updated in GitHub, but no corresponding version found in smartmet-open or smartmet-open-beta).

Initially a local copy of required GitHub repositories is created according to configuration. In this phase additional smartmet* repositories are cloned from GitHub according to dependencies as required.

After that script **smartbuild** goes through all cloned repositories according to dependencies and checks whether last version (according to the SPEC file present in repository) if found in smartmet-open or smartmet-open-beta:
* packages installed from smartmet-open or smartmet-open-beta if found there
* otherwise RPM packages are built and freshly built packages installed
For example smartmet-library-spine depends on smartmet-utils-devel, smartmet-library-macgyver, smartmet-library-gis and smartmet-library-newbase. Dependencies are tracked recursively and built (or installed) before building or installing package which requires them. Note that packages may be installed or built in different order each time as far as dependency order is obeyed.

Finally:
* all build or install log files are archived and added as build artifact
* all build RPM packages are added as build artifact in form of a single tar archived
* RPM packages are uploaded to smartmet-open-beta in case that there were no errors. Failure to build one on more packages prevents upload. User may decide in this to download tar archive with all successfully built RPM packages from build artifacts and put them in smartmet-open manually if needed

Possible error cases:
* release and revision of newest packages from smartmet-open or smartmet-open-beta is newer than version from SPEC file : perhaps Git push missing
