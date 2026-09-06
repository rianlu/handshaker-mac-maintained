# 解析 ioreg -p IOUSB -l -w0 输出: 定位手机节点, 提取其属性与祖先链.
# 输出键值行:
#   PHONE_NODE / PHONE_NAME / PHONE_VID / PHONE_PID / PHONE_LINK_BPS / PHONE_SPEED_ENUM
#   ANCESTOR=<depth>|<nodename>|<vendor>|<isHub>
#   无手机时: PHONE_NONE=1
function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
function val(line, key,   v) {
  v = line
  if (sub(".*\"" key "\" = ", "", v)) {
    sub(/,$/, "", v)
    gsub(/^"|"$/, "", v)
    return trim(v)
  }
  return ""
}
{
  L[++n] = $0
  prefix = $0
  sub(/[+\\]-o .*/, "", prefix)
  if (prefix != $0 && prefix ~ /^[ |]*$/) {
    nn++
    dep[nn] = length(prefix) / 2
    ln[nn] = n
    atLine[n] = nn
    rest = $0
    sub(/^[ |]*[+\\]-o /, "", rest)
    sub(/[ ]*<class.*/, "", rest)
    nm[nn] = trim(rest)
  }
}
END {
  # 1) 按节点名匹配常见手机厂商
  ph = 0
  for (i = 1; i <= nn; i++)
    if (nm[i] ~ /(OnePlus|一加|Xiaomi|Redmi|Samsung|Google|moto|Pixel|CPH|HUAWEI|Honor|vivo|OPPO|Realme|MEIZU|ZTE|Lenovo|Sony|LG|小米|华为|荣耀|一 plus)/) { ph = i; break }
  # 2) 名字没中: 按属性块内 idVendor=6353 (Google AOA) 兜底
  if (!ph) {
    for (i = 1; i <= nn && !ph; i++) {
      e = (i < nn) ? ln[i+1] - 1 : n
      for (k = ln[i] + 1; k <= e; k++)
        if (L[k] ~ /"idVendor" = 6353/) { ph = i; break }
    }
  }
  if (!ph) { print "PHONE_NONE=1"; exit }

  # 手机自身属性
  bps = ""; en = ""; vi = ""; pid = ""; pn = ""
  e = (ph < nn) ? ln[ph+1] - 1 : n
  for (k = ln[ph] + 1; k <= e; k++) {
    if (bps == "" && L[k] ~ /"UsbLinkSpeed" = /)     bps = val(L[k], "UsbLinkSpeed")
    if (en  == "" && L[k] ~ /"USBSpeed" = /)         en  = val(L[k], "USBSpeed")
    if (vi  == "" && L[k] ~ /"idVendor" = /)         vi  = val(L[k], "idVendor")
    if (pid == "" && L[k] ~ /"idProduct" = /)        pid = val(L[k], "idProduct")
    if (pn  == "" && L[k] ~ /"USB Product Name" = /) pn  = val(L[k], "USB Product Name")
  }
  printf "PHONE_NODE=%s\n", nm[ph]
  printf "PHONE_NAME=%s\n", (pn != "" ? pn : nm[ph])
  printf "PHONE_VID=%s\n", vi
  printf "PHONE_PID=%s\n", pid
  printf "PHONE_LINK_BPS=%s\n", bps
  printf "PHONE_SPEED_ENUM=%s\n", en

  # 祖先链: 从手机向上逐层找深度递减的最近节点(到深度 1, 跳过 Root)
  t = dep[ph] - 1
  for (i = ph - 1; i >= 1 && t >= 1; i--) {
    if (dep[i] == t) {
      vend = ""
      e2 = (i < nn) ? ln[i+1] - 1 : n
      for (k = ln[i] + 1; k <= e2; k++)
        if (vend == "" && L[k] ~ /"kUSBVendorString" = /) vend = val(L[k], "kUSBVendorString")
      hub = (nm[i] ~ /[Hh][Uu][Bb]/) ? 1 : 0
      printf "ANCESTOR=%d|%s|%s|%d\n", dep[i], nm[i], vend, hub
      t--
    }
  }
}
