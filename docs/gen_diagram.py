import json

E = []

def uid(p, n=[0]):
    n[0]+=1
    return f"{p}{n[0]}"

def rect(x,y,w,h,stroke,bg,fill="solid",sw=2,round_=True,id=None):
    el={"type":"rectangle","x":x,"y":y,"width":w,"height":h,
        "strokeColor":stroke,"backgroundColor":bg,"fillStyle":fill,
        "strokeWidth":sw,"id":id or uid("r")}
    if round_: el["roundness"]={"type":3}
    E.append(el); return el["id"]

def text(x,y,w,s,fs=14,h=None,align="left",bold=False):
    lines=s.count("\n")+1
    if h is None: h=int(fs*1.7*lines)+6
    E.append({"type":"text","x":x,"y":y,"width":w,"height":h,"text":s,
        "fontSize":fs,"fontFamily":2 if not bold else 3,"strokeColor":"#000000",
        "id":uid("t"),"textAlign":align,"verticalAlign":"top"})

def ellipse(x,y,w,h,stroke,bg):
    eid=uid("e")
    E.append({"type":"ellipse","x":x,"y":y,"width":w,"height":h,
        "strokeColor":stroke,"backgroundColor":bg,"fillStyle":"solid",
        "strokeWidth":2,"id":eid}); return eid

def arrow(x1,y1,x2,y2,stroke,sw=2,dashed=False,double=False):
    el={"type":"arrow","x":x1,"y":y1,"width":x2-x1,"height":y2-y1,
        "strokeColor":stroke,"strokeWidth":sw,
        "points":[[0,0],[x2-x1,y2-y1]],"id":uid("a"),
        "endArrowhead":"arrow"}
    if double: el["startArrowhead"]="arrow"
    if dashed: el["strokeStyle"]="dashed"
    E.append(el)

# Color palette
BLUE_S,BLUE_B="#0078D4","#CFE4FA"      # hub / central
GREEN_S,GREEN_B="#107C10","#DFF6DD"    # team A
PURP_S,PURP_B="#5C2D91","#E8DAEF"      # team B
ORNG_S,ORNG_B="#F7630C","#FFF4CE"      # AI gateway
GRAY_S,GRAY_B="#495057","#F3F2F1"      # neutral / vnet / obs
RED_S,RED_B="#D13438","#FDE7E9"        # access notes
TEAL_S,TEAL_B="#0c8599","#99e9f2"      # data

# ---- Title ----
text(40,20,1600,"Enterprise Microsoft Foundry — Component-Level Solution Diagram (Sweden Central)",26,h=44,bold=False)
text(40,62,1600,"Hub/spoke topology · private networking · central governed model via Azure AI Gateway (preview)",15,h=24)

# ---- Personas (top) ----
pa=ellipse(250,110,300,70,GREEN_S,GREEN_B); text(260,128,280,"Team A users\n(build agents & apps)",13,align="center")
pc=ellipse(1090,110,320,70,BLUE_S,BLUE_B); text(1100,128,300,"Central cloud / platform team\n(approve & host models, own gateway)",12,align="center")
pb=ellipse(1950,110,300,70,PURP_S,PURP_B); text(1960,128,280,"Team B users\n(build agents & apps)",13,align="center")

# ================= TEAM A RG (left) =================
ax=40; aw=740
rect(ax,250,aw,1180,GREEN_S,"transparent",sw=3)
text(ax+16,262,aw-30,"RG  rg-ai-team-a-swc-dev   (spoke)",15,bold=True)

# VNet A
rect(ax+30,308,aw-60,300,GRAY_S,"transparent",sw=2)
text(ax+44,318,aw-90,"VNet  vnet-ai-team-a · 10.20.0.0/16",13,bold=True)
rect(ax+50,352,aw-100,66,GRAY_S,"#FFFFFF",fill="solid"); text(ax+62,360,aw-120,"snet-foundry-agents · 10.20.1.0/24\ndelegated Microsoft.app/environments",11)
rect(ax+50,426,aw-100,58,GRAY_S,"#FFFFFF"); text(ax+62,438,aw-120,"snet-private-endpoints · 10.20.2.0/24",11)
rect(ax+50,492,aw-100,58,GRAY_S,"#FFFFFF"); text(ax+62,504,aw-120,"snet-team-apps · 10.20.3.0/24",11)

# Foundry A
fa=rect(ax+30,628,aw-60,118,GREEN_S,GREEN_B)
text(ax+44,640,aw-90,"Foundry  fndry-team-a  (AIServices)\nProject: proj-team-a\nAgents injected → agents subnet · PE → PE subnet",12)

# BYO data A
text(ax+30,762,aw-60,"BYO data (Team A) — each via Private Endpoint",12,bold=True)
da1=rect(ax+30,792,(aw-70)//2,80,TEAL_S,TEAL_B); text(ax+42,804,(aw-90)//2,"Storage (Blob)\nPE → PE subnet",11)
da2=rect(ax+40+(aw-70)//2,792,(aw-70)//2,80,TEAL_S,TEAL_B); text(ax+52+(aw-70)//2,804,(aw-90)//2,"AI Search\nPE → PE subnet",11)
da3=rect(ax+30,882,(aw-70)//2,80,TEAL_S,TEAL_B); text(ax+42,894,(aw-90)//2,"Cosmos DB (SQL)\nPE → PE subnet",11)
da4=rect(ax+40+(aw-70)//2,882,(aw-70)//2,80,TEAL_S,TEAL_B); text(ax+52+(aw-70)//2,894,(aw-90)//2,"Key Vault\nPE → PE subnet",11)

# Access note A
rect(ax+30,990,aw-60,150,RED_S,RED_B)
text(ax+44,1002,aw-90,"Team A access (where they work):\n• Work ONLY in proj-team-a within this spoke\n• Data-plane RBAC: fndry-team-a MSI → own Storage/Search/Cosmos/Key Vault\n• Consume the central model ONLY via the AI Gateway alias (no direct access)",11)

# ================= HUB RG (center) =================
hx=820; hw=860
rect(hx,250,hw,1180,BLUE_S,"transparent",sw=3)
text(hx+16,262,hw-30,"RG  rg-ai-hub-swc-dev   (hub)",15,bold=True)

# VNet hub
rect(hx+30,308,hw-60,300,GRAY_S,"transparent",sw=2)
text(hx+44,318,hw-90,"VNet  vnet-ai-hub · 10.10.0.0/16",13,bold=True)
rect(hx+50,352,hw-100,66,GRAY_S,"#FFFFFF"); text(hx+62,360,hw-120,"snet-aigw-integration · 10.10.1.0/24\ndelegated Microsoft.App/environments · NSG attached",11)
rect(hx+50,426,hw-100,58,GRAY_S,"#FFFFFF"); text(hx+62,438,hw-120,"snet-private-endpoints · 10.10.2.0/24",11)
rect(hx+50,492,hw-100,58,GRAY_S,"#FFFFFF"); text(hx+62,504,hw-120,"snet-shared-services · 10.10.3.0/24",11)

# AI Gateway
aigw=rect(hx+30,628,hw-60,108,ORNG_S,ORNG_B)
text(hx+44,638,hw-90,"Azure AI Gateway  aigw-ai-swc-dev-*  (preview)\nPer-team aliases + alias-scoped Entra RBAC · tokenLimit · MSI routing\nOutbound → aigw integration subnet · Inbound: public (optional PE)",12)

# Central Foundry
cf=rect(hx+30,752,hw-60,116,BLUE_S,BLUE_B)
text(hx+44,762,hw-90,"Foundry  fndry-central  (AIServices) — governed\nProject: proj-central · PE → PE subnet\nModel: enterprise-gpt5-mini (gpt-5-mini · GlobalStandard)",12)

# Private DNS
rect(hx+30,884,hw-60,96,GRAY_S,GRAY_B)
text(hx+44,894,hw-90,"Private DNS zones (7): cognitiveservices · openai · services.ai\n· search · documents · blob · vaultcore\nLinked to hub + both spokes",11)

# Governance note
rect(hx+30,996,hw-60,144,BLUE_S,"#EAF3FC")
text(hx+44,1008,hw-90,"Central cloud team access (what they own):\n• Govern the hub: approve & host the model centrally\n• Own the AI Gateway, aliases, policies & alias RBAC\n• NO access to team spokes or team BYO data",11)

# ================= TEAM B RG (right) =================
bx=1720; bw=740
rect(bx,250,bw,1180,PURP_S,"transparent",sw=3)
text(bx+16,262,bw-30,"RG  rg-ai-team-b-swc-dev   (spoke)",15,bold=True)

rect(bx+30,308,bw-60,300,GRAY_S,"transparent",sw=2)
text(bx+44,318,bw-90,"VNet  vnet-ai-team-b · 10.30.0.0/16",13,bold=True)
rect(bx+50,352,bw-100,66,GRAY_S,"#FFFFFF"); text(bx+62,360,bw-120,"snet-foundry-agents · 10.30.1.0/24\ndelegated Microsoft.app/environments",11)
rect(bx+50,426,bw-100,58,GRAY_S,"#FFFFFF"); text(bx+62,438,bw-120,"snet-private-endpoints · 10.30.2.0/24",11)
rect(bx+50,492,bw-100,58,GRAY_S,"#FFFFFF"); text(bx+62,504,bw-120,"snet-team-apps · 10.30.3.0/24",11)

fb=rect(bx+30,628,bw-60,118,PURP_S,PURP_B)
text(bx+44,640,bw-90,"Foundry  fndry-team-b  (AIServices)\nProject: proj-team-b\nAgents injected → agents subnet · PE → PE subnet",12)

text(bx+30,762,bw-60,"BYO data (Team B) — each via Private Endpoint",12,bold=True)
rect(bx+30,792,(bw-70)//2,80,TEAL_S,TEAL_B); text(bx+42,804,(bw-90)//2,"Storage (Blob)\nPE → PE subnet",11)
rect(bx+40+(bw-70)//2,792,(bw-70)//2,80,TEAL_S,TEAL_B); text(bx+52+(bw-70)//2,804,(bw-90)//2,"AI Search\nPE → PE subnet",11)
rect(bx+30,882,(bw-70)//2,80,TEAL_S,TEAL_B); text(bx+42,894,(bw-90)//2,"Cosmos DB (SQL)\nPE → PE subnet",11)
rect(bx+40+(bw-70)//2,882,(bw-70)//2,80,TEAL_S,TEAL_B); text(bx+52+(bw-70)//2,894,(bw-90)//2,"Key Vault\nPE → PE subnet",11)

rect(bx+30,990,bw-60,150,RED_S,RED_B)
text(bx+44,1002,bw-90,"Team B access (where they work):\n• Work ONLY in proj-team-b within this spoke\n• Data-plane RBAC: fndry-team-b MSI → own Storage/Search/Cosmos/Key Vault\n• Consume the central model ONLY via the AI Gateway alias (no direct access)",11)

# Live demo access note
rect(hx+30,1180,hw-60,150,RED_S,"#FFF4CE")
text(hx+44,1192,hw-90,"Operator demo access (current network):\n• Deploy checks Foundry + connected data endpoint reachability\n• New network → allow-demo-access.sh adds detected egress ranges\n• Dev opt-out tag keeps Storage / Cosmos / Key Vault IP rules effective\n• Network reachability is separate from portal RBAC / data permissions",11)

# ================= OBSERVABILITY RG (bottom center) =================
rect(hx,1470,hw,150,GRAY_S,"transparent",sw=3)
text(hx+16,1482,hw-30,"RG  rg-ai-observability-swc-dev",15,bold=True)
rect(hx+30,1516,hw-60,86,GRAY_S,GRAY_B)
text(hx+44,1526,hw-90,"Central + team Log Analytics / Application Insights\nDiagnostic settings from Foundry (central + teams) · Storage/Search/Cosmos/Key Vault\nAI Gateway OpenTelemetry export: manual post-deploy step",11)

# ================= ARROWS / RELATIONS =================
# Peering hub <-> team A  (left edge of hub vnet to right edge of team A vnet)
arrow(hx+30,470,ax+aw-30,470,GRAY_S,sw=3,double=True)
text(ax+aw-10,420,260,"VNet peering",11,align="center")
# Peering hub <-> team B
arrow(hx+hw-30,470,bx+30,470,GRAY_S,sw=3,double=True)
text(bx-150,420,260,"VNet peering",11,align="center")

# Team A project -> AI Gateway (uses model via its alias)
arrow(ax+aw-30,687,hx+30,682,ORNG_S,sw=2,dashed=True)
text(ax+aw-10,640,300,"uses team alias via\nAI Gateway (connection)",10,align="center")
# Team B project -> AI Gateway
arrow(bx+30,687,hx+hw-30,682,ORNG_S,sw=2,dashed=True)
text(bx-180,640,300,"uses team alias via\nAI Gateway (connection)",10,align="center")

# AI Gateway -> Central Foundry model (MSI)
arrow(hx+hw//2,736,hx+hw//2,752,BLUE_S,sw=3)
text(hx+hw//2+10,724,360,"MSI: Foundry User",10)

# Personas -> their areas
arrow(400,180,ax+aw//2,628,GREEN_S,sw=2)        # team A users -> foundry A
arrow(1250,180,hx+hw//2,628,BLUE_S,sw=2)         # central team -> gateway/hub
arrow(2100,180,bx+bw//2,628,PURP_S,sw=2)         # team B users -> foundry B

# Direct-access-blocked annotation
rect(hx+30,1180,hw-60,70,RED_S,RED_B)
text(hx+44,1190,hw-90,"Isolation enforced: teams CANNOT call the central model endpoint directly\n(no role on central Foundry → 401/403; only the AI Gateway MSI is granted Foundry User).",11)

out={"type":"excalidraw","version":2,"source":"copilot",
     "elements":E,"appState":{"viewBackgroundColor":"#ffffff","gridSize":None}}
with open(r"C:\_CODE\enterprise-foundry\docs\solution-diagram.excalidraw","w",encoding="utf-8") as f:
    json.dump(out,f,indent=2)
print("elements:",len(E))
