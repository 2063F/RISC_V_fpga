set device_names {
    "GW5A-LV25MG121NC1/I0"
    "GW5A-LV25MG121"
    "GW5A-25A"
    "GW5A-LV25"
    "GW5A-LV25MG121C1/I0"
    "GW5A-LV25MG121NES"
}

foreach dev $device_names {
    if {[catch {create_project -name "test_proj" -dir "test_dir" -pn $dev -force} err]} {
        puts "Device: $dev -> FAILED: $err"
    } else {
        puts "Device: $dev -> SUCCESS!"
        project close
    }
}
exit
