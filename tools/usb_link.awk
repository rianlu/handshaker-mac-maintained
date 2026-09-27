# Read ioreg -p IOUSB -l -w0. Select the requested serial, then its saved port.
# Preserve spaces in names. Inspect only the selected phone's ancestors.
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function value(s) { sub(/^[^=]*= /, "", s); s=trim(s); sub(/^"/, "", s); sub(/"$/, "", s); return s }
function isphone(i, name) {
    name=tolower(node[i] " " prop[i,"USB Vendor Name"])
    return (prop[i,"idVendor"]==6353 && prop[i,"idProduct"]>=11520 && prop[i,"idProduct"]<=11525) || name ~ /oneplus|一加|xiaomi|redmi|samsung|pixel|motorola|moto |cph[0-9]|huawei|honor|vivo|oppo|realme|meizu|小米|华为|荣耀/
}
/^[ |]*[+\\]-o / {
    prefix=$0; sub(/[+\\]-o .*/, "", prefix)
    level=length(prefix)/2
    i=++nodes; depth[i]=level
    parent[i]=(level>0 ? stack[level-1] : 0); stack[level]=i
    node[i]=$0; sub(/^[ |]*[+\\]-o /, "", node[i]); sub(/[ ]*<class.*/, "", node[i])
    next
}
/^[ |]*"(USB Serial Number|USB Product Name|USB Vendor Name|kUSBVendorString|idVendor|idProduct|bDeviceClass|UsbLinkSpeed|USBSpeed|locationID|built-in|non-removable)" = / {
    key=$0; sub(/^[ |]*"/, "", key); sub(/" = .*/, "", key)
    prop[nodes,key]=value($0)
}
END {
    selected=0; matches=0; selection="serial"
    if (target_serial!="") for (i=1;i<=nodes;i++) if (prop[i,"USB Serial Number"]==target_serial) {selected=i; matches++}
    if (!matches && target_location!="") {
        selection="port"
        for (i=1;i<=nodes;i++) if (prop[i,"locationID"]==target_location && prop[i,"idVendor"]!="" && prop[i,"bDeviceClass"]!=9) {selected=i; matches++}
    }
    if (!matches && target_serial=="" && target_location=="") {
        selection="single-phone-candidate"
        for (i=1;i<=nodes;i++) if (isphone(i)) {selected=i; matches++}
    }
    if (matches!=1) {
        print "PHONE_NONE=1"
        print "PHONE_CANDIDATES=" matches
        if (matches>1) print "PHONE_AMBIGUOUS=1"
        exit
    }
    printf "PHONE_SELECTION=%s\nPHONE_NODE=%s\n", selection, node[selected]
    printf "PHONE_NAME=%s\n", (prop[selected,"USB Product Name"]!="" ? prop[selected,"USB Product Name"] : node[selected])
    keys[1]="idVendor"; keys[2]="idProduct"; keys[3]="UsbLinkSpeed"; keys[4]="USBSpeed"; keys[5]="USB Serial Number"; keys[6]="locationID"
    names[1]="VID"; names[2]="PID"; names[3]="LINK_BPS"; names[4]="SPEED_ENUM"; names[5]="SERIAL"; names[6]="LOCATION"
    for (k=1;k<=6;k++) printf "PHONE_%s=%s\n", names[k], prop[selected,keys[k]]
    hubs=0; external=0; internal=0
    for (i=parent[selected];i>0;i=parent[i]) {
        if (depth[i]==0) continue
        vendor=prop[i,"USB Vendor Name"]
        if (vendor=="") vendor=prop[i,"kUSBVendorString"]
        hub=(prop[i,"bDeviceClass"]==9 || tolower(node[i]) ~ /hub/)
        builtin=(tolower(node[i]) ~ /roothub|root hub|internalhub|internal hub/ || prop[i,"built-in"]=="Yes" || prop[i,"built-in"]=="1" || (vendor ~ /Apple/ && prop[i,"non-removable"]=="Yes"))
        kind=hub ? (builtin ? "internal" : "external-or-unspecified") : "controller"
        printf "ANCESTOR=%d|%s|%s|%d|%s\n", depth[i], node[i], vendor, hub, kind
        if (hub) {hubs++; if (builtin) internal++; else external++}
    }
    printf "HUB_ANCESTORS=%d\nINTERNAL_HUBS=%d\nOTHER_HUBS=%d\n", hubs, internal, external
}
