set versions {"" "A" "B" "C"}
foreach ver $versions {
    if {$ver == ""} {
        if {[catch {create_project -name "test_proj" -dir "test_dir" -pn "GW5A-LV25MG121NC1/I0" -force} err]} {
            puts "Version: (none) -> FAILED: $err"
        } else {
            puts "Version: (none) -> SUCCESS!"
            project close
        }
    } else {
        if {[catch {create_project -name "test_proj" -dir "test_dir" -pn "GW5A-LV25MG121NC1/I0" -device_version $ver -force} err]} {
            puts "Version: $ver -> FAILED: $err"
        } else {
            puts "Version: $ver -> SUCCESS!"
            project close
        }
    }
}
exit
