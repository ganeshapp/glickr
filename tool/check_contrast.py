def lin(c):
    c=c/255.0
    return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def L(h):
    h=h.lstrip('#'); return 0.2126*lin(int(h[0:2],16))+0.7152*lin(int(h[2:4],16))+0.0722*lin(int(h[4:6],16))
def cr(a,b):
    l1,l2=L(a),L(b)
    if l1<l2: l1,l2=l2,l1
    return (l1+0.05)/(l2+0.05)
def t(r): return "AAA" if r>=7 else ("AA" if r>=4.5 else ("AA-lg" if r>=3 else "FAIL"))
pairs=[
 ("DARK success #7FC08A / surface","#7FC08A","#1B1017"),
 ("DARK warning #E0B15E / surface","#E0B15E","#1B1017"),
 ("DARK info    #A9A8C8 / surface","#A9A8C8","#1B1017"),
 ("DARK success / surfaceContainer","#7FC08A","#241722"),
 ("DARK warning / surfaceContainer","#E0B15E","#241722"),
 ("LIGHT success #2E7042 / surface","#2E7042","#FBF6F4"),
 ("LIGHT warning #8A5A00 / surface","#8A5A00","#FBF6F4"),
 ("LIGHT info    #414370 / surface","#414370","#FBF6F4"),
 ("DARK onSurfaceVariant / sCHigh","#C2AEB6","#2E1E2A"),
 ("DARK onSurfaceVariant / sCHighest","#C2AEB6","#3E2A38"),
 ("LIGHT onSurfaceVariant / sCHighest","#5C4A55","#E0D2D4"),
 ("DARK primary / surfaceContainer","#E28FA0","#241722"),
 ("LIGHT primary / surfaceContainer","#A83E56","#F2E9E8"),
 ("DARK onPrimary/primary","#1B1017","#E28FA0"),
]
for lab,a,b in pairs:
    r=cr(a,b); print(f"{lab:40s} = {r:5.2f}:1  {t(r)}")
