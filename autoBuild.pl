#!usr/bin/perl
use File::Path 'rmtree';
use File::Basename;
use Cwd;

# Delete directory if exists
sub RemoveDirIfExists {
    my $dir = $_[0];
    if (-e -d $dir) {
        rmtree($dir, { error => \my $err });
        if ($err && @$err) {
            print "Can't remove directory $temp_dir, $err";
            exit -1;
        }
    }
}

# Get plist value
sub ReadInfoPlist {
    my $plist_file = $_[0];
    my $key = $_[1];
    my $result = `defaults read $plist_file $key`;
    return $result;
}

# Temporary directory
$root_path = $ENV{"SRCROOT"};
$temp_dir = $root_path . "/temp";
# Empty 'temp' directory
RemoveDirIfExists($temp_dir);
mkdir($temp_dir) or die "Can't create temp directory, $!";
# IPA store directory
$target_app_dir = $root_path . "/targetApp";
# IPA file (get first)
@ipa_files = glob( "$target_app_dir/*.ipa" );
$ipa_path = $ipa_files[0];
print "ipa path: $ipa_path\n";
-e -f -r $ipa_path or die "IPA file not found at $target_app_dir\n";
system "unzip", "-oqq", $ipa_path, "-d", $temp_dir;
$? == 0 or die "Fail to unzip IPA file $ipa_path";

my $app_package_path = $ENV{"BUILT_PRODUCTS_DIR"} . "/" . $ENV{"TARGET_NAME"} . ".app";
my $info_plist_file = $app_package_path . "/Info.plist";

# Export entitlements 'embedded.mobileprovision' to tmp
my $entitlements_file = $temp_dir . "/tmp.plist";
my $original_ent_file = $app_package_path . "/embedded.mobileprovision";
print "raw entitlements file: $original_ent_file\n";
system("codesign -d --entitlements :- $app_package_path > $entitlements_file");
die "Fail to export entitlements, $!" if $? != 0;

# Copy ipa resource to replace destination app package
RemoveDirIfExists($app_package_path);
mkdir($app_package_path) or die "Can't create $app_package_path directory, $!";

$temp_app_path = (glob "$temp_dir/Payload/*.app")[0];
print "temp_app_path = $temp_app_path\n";
system "cp", "-rf", ($temp_app_path . "/"), $app_package_path;
die "Can't copy package to $app_package_path" if $? != 0;

my $display_name = ReadInfoPlist($temp_app_path . "/Info.plist", "CFBundleDisplayName");
$display_name =~ s/\\u(....)/ pack 'U*', hex($1) /eg;
print "display name: $display_name\n";

# Rename mach-o file
my ($ipa_name, undef, undef) = fileparse($temp_app_path, "\.app");
my ($fake_app_name, undef, undef) = fileparse($app_package_path, "\.app");
print "ipa_name: $ipa_name, app_name: $fake_app_name\n";
my $old_app_path = $app_package_path . "/" . $ipa_name;
my $new_app_path = $app_package_path . "/" . $fake_app_name;
rename($old_app_path, $new_app_path) or die "Can't rename mach-o file $!";

# Restore mach-o file symbols (without blocks)
#my $restore_symbol_path = $root_path . "/restore-symbol";
#my $restorer = $restore_symbol_path . "/restore-symbol";
#if (not(-e -f $restorer) || defined($ENV{"FAKE_ALWAYS_UPDATE_SUBMODULE"})) {
#    # Initialize 'restore-symbol' submodule
#    system "git submodule update --init --recursive";
#    die "Can't init submodule, $!" if $? != 0;
#    my $original_cwd = cwd;
#    chdir($restore_symbol_path) or die "Can't change to directory $restore_symbol_path, $!";
#    system "make";
#    die "Can't build submodule 'restore-symbol', $!" if $? != 0;
#    chdir($original_cwd);
#}
#system $restorer, $old_app_path, "-o", $new_app_path;
#die "Fail to restore symbols: $new_app_path" if $? != 0;

# Add execute permission
system "chmod", "u+x", $app_package_path;
print "app add execute permission $app_package_path\n";
die "Can't add execute permission to $app_package_path" if $? != 0;
system "chmod", "u+x", $new_app_path;
die "Can't add execute permission to $new_app_path" if $? != 0;

# Remove 'Plugins' and 'Watch' directory
$plugins_dir = $app_package_path . "/Plugins";
RemoveDirIfExists($plugins_dir);
$watch_dir = $app_package_path . "/Watch";
RemoveDirIfExists($watch_dir);

# Modify info.plist
sub PlistModify {
    my $key = $_[0];
    my $value = $_[1];
    my $plist = $_[2];
    system "/usr/libexec/PlistBuddy", "-c", "Set :$key $value", $plist;
    die "Can't set $key for $value in $plist" if $? != 0;
}

PlistModify("CFBundleIdentifier", $ENV{'PRODUCT_BUNDLE_IDENTIFIER'}, $info_plist_file);
PlistModify("CFBundleName", $fake_app_name, $info_plist_file);
PlistModify("CFBundleDisplayName", ($display_name . "_f"), $info_plist_file);
PlistModify("CFBundleExecutable", $fake_app_name, $info_plist_file);

# Resign frameworks
my $frameworks_path = $target_app_dir . "/Frameworks/*";
if (-d $frameworks_path) {
    foreach (glob $frameworks_path) {
        system "/usr/bin/codesign", "-fs", $ENV{"EXPANDED_CODE_SIGN_IDENTITY"}, $_;
        die "Can't sign framework $_" if $? != 0;
    }
}

# Resign mach-o
system "/usr/bin/codesign", "-fs", $ENV{"EXPANDED_CODE_SIGN_IDENTITY"}, $new_app_path;
die "Fail to resign mach-o file, $!" if $? != 0;


