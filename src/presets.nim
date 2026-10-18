## Ready-to-use entities for the entity browser, in collapsible groups.
##
## Built in: one generic object per type, the original game's characters (with
## the team and weapon the game gives them), weapons, power-ups, particles and
## turrets. Their classes all live in level 0, so they work in every level.
##
## Furniture, consoles, doors and triggers come from the entity library
## (library.nim), which Catwalk builds from the game files: their classes are
## level content, and furniture exists only as geometry baked into the level.

import std/[tables, xmltree, xmlparser, strutils, algorithm]
import levelobjects, objtemplates

type
  Preset* = object
    group*: string                    ## Collapsible header in the browser.
    label*: string
    detail*: string                   ## Shown dimmed after the label (the class).
    tag*: string
    generic*: bool                    ## A plain object of the type (copies the level's first one).
    fields*: seq[(string, string)]    ## Element paths set on the template, e.g. ("OSD/Class", "w1_tap").
    xml*: string                      ## Full object XML (library entries); overrides the template.
    prefab*: string                   ## Library geometry file, in object space ("" = none).
    textures*: seq[string]            ## Library images the geometry uses.
    oniFiles*: seq[string]            ## Library .oni files the object needs packed with the level.
    doorCenter*: string               ## DOOR: OSD/Center in object space.
    modelTexture*: string             ## DOOR: library image for its preview (the level's Texture1).

const
  GenericGroup* = "Generic"

  ## (group, class, label, team, weapon, flags). Characters start in the level
  ## (no NotInitiallyPresent), unlike the game's, which its scripts spawn.
  Characters = [
    ("Player", "konoko_generic", "Konoko", "Konoko", "", "IsPlayer"),
    ("Player", "k3", "Konoko (chapter 3 outfit)", "Konoko", "", "IsPlayer"),
    ("Player", "k4_A", "Konoko (k4_A)", "Konoko", "", "IsPlayer"),
    ("Player", "k4_F", "Konoko (k4_F)", "Konoko", "", "IsPlayer"),
    ("Player", "k4_G", "Konoko (k4_G)", "Konoko", "", "IsPlayer"),
    ("Player", "k4_K", "Konoko (k4_K)", "Konoko", "", "IsPlayer"),
    ("Player", "k4_L", "Konoko (k4_L)", "Konoko", "", "IsPlayer"),
    ("Enemies: Strikers", "striker_easy_1", "Striker, easy 1", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_easy_2", "Striker, easy 2", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_easy_3", "Striker, easy 3", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_med_1", "Striker, medium 1", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_med_2", "Striker, medium 2", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_med_3", "Striker, medium 3", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_hard_1", "Striker, hard 1", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_hard_2", "Striker, hard 2", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_hard_3", "Striker, hard 3", "Syndicate", "", ""),
    ("Enemies: Strikers", "striker_dream_lab", "Striker, dream lab", "Syndicate", "", ""),
    ("Enemies: Comguys", "comguy_1", "Comguy 1", "Syndicate", "w2_sap", ""),
    ("Enemies: Comguys", "comguy_2", "Comguy 2", "Syndicate", "w2_sap", ""),
    ("Enemies: Comguys", "comguy_3", "Comguy 3", "Syndicate", "w2_sap", ""),
    ("Enemies: Tankers", "tanker_easy_1", "Tanker, easy", "Syndicate", "", ""),
    ("Enemies: Tankers", "tanker_med_1", "Tanker, medium", "Syndicate", "", ""),
    ("Enemies: Tankers", "tanker_hard_1", "Tanker, hard", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_easy_1", "Ninja, easy 1", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_easy_2", "Ninja, easy 2", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_easy_3", "Ninja, easy 3", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_med_1", "Ninja, medium 1", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_med_2", "Ninja, medium 2", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_med_3", "Ninja, medium 3", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_hard_1", "Ninja, hard 1", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_hard_2", "Ninja, hard 2", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninja_hard_3", "Ninja, hard 3", "Syndicate", "", ""),
    ("Enemies: Ninjas", "super_ninja_1", "Super ninja", "Syndicate", "", ""),
    ("Enemies: Ninjas", "ninjabot", "Ninja bot", "Syndicate", "", ""),
    ("Enemies: Elites", "elite_easy_1", "Elite, easy 1", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_easy_2", "Elite, easy 2", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_easy_3", "Elite, easy 3", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_med_1", "Elite, medium 1", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_med_2", "Elite, medium 2", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_med_3", "Elite, medium 3", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_hard_1", "Elite, hard 1", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_hard_2", "Elite, hard 2", "Syndicate", "w3_phr", ""),
    ("Enemies: Elites", "elite_hard_3", "Elite, hard 3", "Syndicate", "w3_phr", ""),
    ("Enemies: Red", "red_easy_1", "Red, easy 1", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_easy_2", "Red, easy 2", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_easy_3", "Red, easy 3", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_med_1", "Red, medium 1", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_med_2", "Red, medium 2", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_med_3", "Red, medium 3", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_hard_1", "Red, hard 1", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_hard_2", "Red, hard 2", "Syndicate", "w4_psm", ""),
    ("Enemies: Red", "red_hard_3", "Red, hard 3", "Syndicate", "w4_psm", ""),
    ("Enemies: Thugs", "thug_wh_1", "Warehouse thug 1", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_wh_2", "Warehouse thug 2", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_wh_3", "Warehouse thug 3", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_wh_4", "Warehouse thug 4", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_wh_5", "Warehouse thug 5", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_mfg_1", "Factory thug 1", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_mfg_2", "Factory thug 2", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_mfg_3", "Factory thug 3", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_mfg_4", "Factory thug 4", "Syndicate", "", ""),
    ("Enemies: Thugs", "thug_mfg_5", "Factory thug 5", "Syndicate", "", ""),
    ("Enemies: Specialists", "sniper_generic", "Sniper", "Syndicate", "w8_mbo", ""),
    ("Enemies: Specialists", "mad_bomber", "Mad bomber", "Syndicate", "", ""),
    ("Bosses", "muro_generic", "Muro", "Syndicate", "", "Boss"),
    ("Bosses", "mutantmuro", "Mutant Muro", "Syndicate", "", "Boss"),
    ("Bosses", "barabus", "Barabus", "Syndicate", "w11_ba1", "Boss"),
    ("Bosses", "SH_generic", "Shinatama", "Syndicate", "", ""),
    ("Bosses", "SH_dream_lab", "Shinatama, dream lab", "RogueKonoko", "", ""),
    ("TCTF", "TCTF_lite_1", "TCTF trooper", "TCTF", "w1_tap", ""),
    ("TCTF", "TCTF_swat_1", "TCTF SWAT", "TCTF", "w3_phr", ""),
    ("TCTF", "TCTF_lite_blackops_1", "TCTF black ops trooper", "TCTF", "w3_phr", ""),
    ("TCTF", "TCTF_swat_blackops_1", "TCTF black ops SWAT", "TCTF", "w6_vdg", ""),
    ("TCTF", "security_guard_1", "Security guard 1", "TCTF", "w1_tap", ""),
    ("TCTF", "security_guard_2", "Security guard 2", "TCTF", "w1_tap", ""),
    ("TCTF", "CopmaleA1", "Cop (male) 1", "TCTF", "w1_tap", ""),
    ("TCTF", "CopmaleA2", "Cop (male) 2", "TCTF", "w1_tap", ""),
    ("TCTF", "CopmaleA3", "Cop (male) 3", "TCTF", "w1_tap", ""),
    ("TCTF", "CopmaleA4", "Cop (male) 4", "TCTF", "w1_tap", ""),
    ("TCTF", "CopfemA1", "Cop (female) 1", "TCTF", "w1_tap", ""),
    ("TCTF", "CopfemA2", "Cop (female) 2", "TCTF", "w1_tap", ""),
    ("TCTF", "griffin_generic", "Griffin", "TCTF", "", ""),
    ("TCTF", "griffin_swat", "Griffin (SWAT)", "TCTF", "w6_vdg", ""),
    ("Civilians", "Shinzom_generic", "Hasegawa (Shinzom)", "Neutral", "", "NonCombatant"),
    ("Civilians", "bd_1", "Scientist 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "bd_2", "Scientist 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "bd_3", "Scientist 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "bd_4", "Scientist 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "bd_5", "Scientist 5", "Neutral", "", "NonCombatant"),
    ("Civilians", "bdfem_1", "Scientist (female) 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "bdfem_2", "Scientist (female) 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "bdfem_3", "Scientist (female) 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "bdfem_4", "Scientist (female) 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_1", "Civilian (male) 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_2", "Civilian (male) 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_3", "Civilian (male) 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_4", "Civilian (male) 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_5", "Civilian (male) 5", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_male_6", "Civilian (male) 6", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_1", "Civilian (female) 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_2", "Civilian (female) 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_3", "Civilian (female) 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_4", "Civilian (female) 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_5", "Civilian (female) 5", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_6", "Civilian (female) 6", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_7", "Civilian (female) 7", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_8", "Civilian (female) 8", "Neutral", "", "NonCombatant"),
    ("Civilians", "generic_female_9", "Civilian (female) 9", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_air_1", "Airport worker 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_air_2", "Airport worker 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_air_3", "Airport worker 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_air_4", "Airport worker 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_air_5", "Airport worker 5", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_neuro_1", "Neuro worker 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_neuro_2", "Neuro worker 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_neuro_3", "Neuro worker 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_neuro_4", "Neuro worker 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_neuro_5", "Neuro worker 5", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_pow_1", "Power plant worker 1", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_pow_2", "Power plant worker 2", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_pow_3", "Power plant worker 3", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_pow_4", "Power plant worker 4", "Neutral", "", "NonCombatant"),
    ("Civilians", "thug_pow_5", "Power plant worker 5", "Neutral", "", "NonCombatant")]

  Weapons = [
    ("w1_tap", "Campbell Equalizer (pistol)"), ("w2_sap", "Spitfire automatic pistol"),
    ("w3_phr", "Plasma rifle"), ("w4_psm", "Phase stream projector"),
    ("w5_sbg", "Superball gun"), ("w6_vdg", "Van de Graaff gun"),
    ("w7_scc", "Scram cannon"), ("w8_mbo", "Mercury bow"),
    ("w9_scr", "Screaming cannon"), ("w10_sni", "Sniper rifle (unused)"),
    ("w11_ba1", "Barabus' weapon 1"), ("w12_ba2", "Barabus' weapon 2")]

  PowerUps = [
    ("Hypo", "Hypo spray"), ("Ammo", "Ballistic ammo"), ("EnergyCell", "Energy cell"),
    ("Shield", "Force shield"), ("Invisibility", "Phase cloak"), ("LSI", "LSI (mission item)")]

  ## Turret classes and the team they shoot at by default.
  Turrets = [
    ("phr_turret_wall", "Plasma turret, wall"), ("phr_turret_ciel", "Plasma turret, ceiling"),
    ("phr_turret_floor", "Plasma turret, floor"), ("mbo_turret_wall", "Mercury bow turret, wall"),
    ("mbo_turret_ciel", "Mercury bow turret, ceiling"), ("sap_turret_wall", "SAP turret, wall"),
    ("sap_turret_ciel", "SAP turret, ceiling"), ("sap_turret_floor", "SAP turret, floor"),
    ("vdg_turret_wall", "Van de Graaff turret, wall"), ("scr_turret_wall", "Screaming turret, wall"),
    ("scr_turret_floor", "Screaming turret, floor")]

  ## (group, class, decal scale). Every particle class the game's levels place
  ## that level 0 has; decals' textures are level content (see DecalTextures).
  Particles = [
  # Lights
  ("Lights", "emlight2", "1 1"), ("Lights", "env_emlite_e01", "1 1"),
  ("Lights", "env_emlite_e02", "1 1"), ("Lights", "env_emlite_e02a", "1 1"),
  ("Lights", "env_emlite_e03", "1 1"), ("Lights", "env_emlite_e04", "1 1"),
  ("Lights", "env_emlite_e05", "1 1"), ("Lights", "env_emlite_p03", "1 1"),
  ("Lights", "env_emlite_p03a", "1 1"), ("Lights", "env_lensflare01", "1 1"),
  ("Lights", "env_lensflare01a", "1 1"), ("Lights", "env_lensflare01b", "1 1"),
  ("Lights", "env_lensflare01b_sml", "1 1"), ("Lights", "env_lensflare01c", "0 0"),
  ("Lights", "env_lensflare01d", "1 1"), ("Lights", "env_lensflare01e", "1 1"),
  ("Lights", "env_lensflare01e_blu", "1 1"), ("Lights", "env_lensflare01e_red_big", "1 1"),
  ("Lights", "env_lensflare01f", "1 1"), ("Lights", "env_lensflare03a", "0 0"),
  ("Lights", "env_lensflare06", "1 1"), ("Lights", "env_lensflare09", "1 1"),
  ("Lights", "env_lensflare11a", "1 1"), ("Lights", "env_lensflare11d", "1 1"),
  ("Lights", "env_lensflare11d_red", "1 1"), ("Lights", "env_lensflare11d_sqr", "1 1"),
  # Fire & smoke
  ("Fire & smoke", "env_exp1_e01", "1 1"), ("Fire & smoke", "env_fire12_e01", "1 1"),
  ("Fire & smoke", "env_fire4_e01", "1 1"), ("Fire & smoke", "env_fire4a_e01", "1 1"),
  ("Fire & smoke", "env_fire5_e01", "1 1"), ("Fire & smoke", "env_fire5a_e01", "1 1"),
  ("Fire & smoke", "env_fire7_e01", "1 1"), ("Fire & smoke", "env_fire9_e01", "1 1"),
  ("Fire & smoke", "env_smoke1_e01", "1 1"), ("Fire & smoke", "env_smoke2_e01", "1 1"),
  ("Fire & smoke", "env_smoke4_e01", "1 1"),
  # Steam & fluids
  ("Steam & fluids", "env_coolant_e01", "1 1"), ("Steam & fluids", "env_coolant_e01a", "1 1"),
  ("Steam & fluids", "env_gas4_e01", "1 1"), ("Steam & fluids", "env_splash_e02", "1 1"),
  ("Steam & fluids", "env_steam1_e03", "1 1"), ("Steam & fluids", "env_steam2_e01", "1 1"),
  ("Steam & fluids", "env_steam3_e01", "1 1"), ("Steam & fluids", "env_steam3_e01a", "1 1"),
  ("Steam & fluids", "env_steam4_e01", "1 1"), ("Steam & fluids", "env_steam4_e02", "1 1"),
  ("Steam & fluids", "env_steam9_e01", "1 1"), ("Steam & fluids", "env_steam_e01", "1 1"),
  ("Steam & fluids", "env_steam_e01a", "1 1"), ("Steam & fluids", "env_steam_e01b", "1 1"),
  ("Steam & fluids", "env_toxic_bubble_e01", "1 1"),
  ("Steam & fluids", "env_toxic_suds_e01", "1 1"), ("Steam & fluids", "env_vat_e01", "1 1"),
  # Sparks & energy
  ("Sparks & energy", "env_arc1_e00", "1 1"), ("Sparks & energy", "env_arc1_e00a", "1 1"),
  ("Sparks & energy", "env_elec1_e01", "1 1"), ("Sparks & energy", "env_elec_e01", "1 1"),
  ("Sparks & energy", "env_elec_e02", "1 1"), ("Sparks & energy", "env_power_e01", "1 1"),
  ("Sparks & energy", "env_sprk1_e01", "1 1"), ("Sparks & energy", "env_sprk1_e02", "1 1"),
  ("Sparks & energy", "env_sprk2_e01", "1 1"), ("Sparks & energy", "env_sprk3_e01", "1 1"),
  ("Sparks & energy", "env_sprk4_e01", "1 1"), ("Sparks & energy", "env_sprk4_e01a", "1 1"),
  ("Sparks & energy", "env_tc1_e01", "1 1"), ("Sparks & energy", "env_tc1_e01a", "1 1"),
  ("Sparks & energy", "env_tc2_e01", "1 1"), ("Sparks & energy", "env_tc2_e01a", "1 1"),
  ("Sparks & energy", "env_tc3_e01", "1 1"), ("Sparks & energy", "env_tc3_e01a", "1 1"),
  ("Sparks & energy", "env_volt2_e01", "1 1"),
  # Weather & ambience
  ("Weather & ambience", "env_bug2_e01", "1 1"), ("Weather & ambience", "env_bugs_e01", "1 1"),
  ("Weather & ambience", "env_cloud01_e01", "1 1"),
  ("Weather & ambience", "env_cloud01_e01b", "1 1"),
  ("Weather & ambience", "env_cloud02_p02", "1 1"), ("Weather & ambience", "env_cloud_e03", "1 1"),
  ("Weather & ambience", "env_dust_e01", "1 1"), ("Weather & ambience", "env_dust_e01a", "1 1"),
  ("Weather & ambience", "env_dust_e03", "1 1"), ("Weather & ambience", "env_fog_e01", "1 1"),
  ("Weather & ambience", "env_fog_e02", "1 1"), ("Weather & ambience", "env_rain_e01", "1 1"),
  ("Weather & ambience", "env_rat_e01", "1 1"), ("Weather & ambience", "env_rat_e02", "1 1"),
  ("Weather & ambience", "env_snow_e01", "1 1"), ("Weather & ambience", "env_squid_e01", "1 1"),
  ("Weather & ambience", "env_wind_e01", "1 1"),
  # Markers & effects
  ("Markers & effects", "arrow", "1 1"), ("Markers & effects", "barwave_e01", "1 1"),
  ("Markers & effects", "forcefield_e01", "1 1"), ("Markers & effects", "item_e01", "1 1"),
  ("Markers & effects", "objective_e01", "1 1"),
  # Decals
  ("Decals", "d_MC_CRACK", "10 10"), ("Decals", "d_MC_DCBLUJIG", "3 3"),
  ("Decals", "d_MC_DCBLUMON", "1.5 3"), ("Decals", "d_MC_DCCYL", "1.5 1.5"),
  ("Decals", "d_MC_DCFIBGLAS", "3 3"), ("Decals", "d_MC_DCLILTE", "1.5 1.5"),
  ("Decals", "d_MC_DCLOGO", "5 5"), ("Decals", "d_MPC_DCLTSWTCH", "0.7 1"),
  ("Decals", "d_MPC_DC_CAUTN", "11 2"), ("Decals", "d_PPII_DC1006", "3 3"),
  ("Decals", "d_PPII_DCALUMX", "3 3"), ("Decals", "d_PPII_DCLIGHTSW", "1.2 1.3"),
  ("Decals", "d_PPII_DCMACHFAC", "7 3"), ("Decals", "d_PPII_DCMECHBOX", "2 2"),
  ("Decals", "d_PPII_DCSEALED", "5 5"), ("Decals", "d_PPII_DCVENT", "10 7.5"),
  ("Decals", "d_PPII_DCVENT_SM", "3 1.7"), ("Decals", "d_RW_DC01", "8 8"),
  ("Decals", "d_RW_DCLABCYL", "12 2"), ("Decals", "d_RW_DCLABHC", "12 2"),
  ("Decals", "d_RW_DCLABPRE", "12 2"), ("Decals", "d_RW_DCLABRK", "12 2"),
  ("Decals", "d_RW_DCN52", "8 4"), ("Decals", "d_RW_SPRK", "5 5"), ("Decals", "d_SCORCH", "20 20"),
  ("Decals", "d_WH_DCEXT", "3 6"), ("Decals", "d_WH_DCRSTMET", "5 6"),
  ("Decals", "d_WH_DCTRBND", "13 2.5"), ("Decals", "d_WH_DCTRCT1", "6 4"),
  ("Decals", "d_WH_DCTRCT2", "6 4"), ("Decals", "d_WH_DCTRCT3", "6 4"),
  ("Decals", "d_WH_DCTRCT4", "6 4"), ("Decals", "d_WH_DCTRCT5", "6 4"),
  ("Decals", "d_WH_DCTRCT6", "6 4"), ("Decals", "d_WH_DCTRCT7", "6 4"),
  ("Decals", "d_WH_DCVENT", "3 1.7"), ("Decals", "d_WH_DCVENTM", "10 10"),
  ("Decals", "d__BULLETHOLE", "1 1"), ("Decals", "d__PHASEBURN2", "1 1")]

  ## Decals whose texture isn't in level 0: the library keeps a copy of each
  ## TXMP (from the level that has it), packed with any level that uses the decal.
  DecalTextures = {
    "d_MC_CRACK": "MC_CRACK", "d_MC_DCBLUJIG": "MC_DCBLUJIG", "d_MC_DCBLUMON": "MC_DCBLUMON",
    "d_MC_DCCYL": "MC_DCCYL", "d_MC_DCFIBGLAS": "MC_DCFIBGLAS", "d_MC_DCLILTE": "MC_DCLILTE",
    "d_MC_DCLOGO": "MC_DCLOGO", "d_MPC_DC_CAUTN": "MPC_DC_CAUTN", "d_MPC_DCLTSWTCH": "MPC_DCLTSWTCH",
    "d_PPII_DC1006": "PPII_DC1006", "d_PPII_DCALUMX": "PPII_DCALUMX",
    "d_PPII_DCLIGHTSW": "PPII_DCLIGHTSW", "d_PPII_DCMACHFAC": "PPII_DCMACHFACADE",
    "d_PPII_DCMECHBOX": "PPII_DCMECHBOX", "d_PPII_DCSEALED": "PPII_DCSEALED",
    "d_PPII_DCVENT": "PPII_DCVENT", "d_PPII_DCVENT_SM": "PPII_DCVENT_SMALL", "d_RW_DC01": "RW_DC01",
    "d_RW_DCLABCYL": "RW_DCLABCYL", "d_RW_DCLABHC": "RW_DCLABHC", "d_RW_DCLABPRE": "RW_DCLABPRE",
    "d_RW_DCLABRK": "RW_DCLABRK", "d_RW_DCN52": "RW_DCN52", "d_RW_SPRK": "RW_SPRK",
    "d_SCORCH": "SCORCH", "d_WH_DCEXT": "WH_DCEXT", "d_WH_DCRSTMET": "WH_DCRSTMET",
    "d_WH_DCTRBND": "WH_DCTRBND", "d_WH_DCTRCT1": "WH_DCTRCT1", "d_WH_DCTRCT2": "WH_DCTRCT2",
    "d_WH_DCTRCT3": "WH_DCTRCT3", "d_WH_DCTRCT4": "WH_DCTRCT4", "d_WH_DCTRCT5": "WH_DCTRCT5",
    "d_WH_DCTRCT6": "WH_DCTRCT6", "d_WH_DCTRCT7": "WH_DCTRCT7", "d_WH_DCVENT": "WH_DCVENT",
    "d_WH_DCVENTM": "WH_DCVENTM"}.toTable

  ## The per-type script id each object type carries; new objects get the next free one.
  ScriptIdFields* = {"CONS": "OSD/ConsoleId", "DOOR": "OSD/DoorId", "TRIG": "OSD/TriggerId",
    "TURR": "OSD/TurretId", "TRGV": "OSD/TriggerVolumeId", "FLAG": "OSD/FlagId",
    "PATR": "OSD/PatrolId", "NEUT": "OSD/NeutralId"}.toTable

proc decalTextures*(): seq[string] =
  ## Texture names the library must keep for decals.
  for _, t in DecalTextures: result.add t

proc builtinPresets*(): seq[Preset] =
  var tags: seq[string]
  for t in Templates.keys: tags.add t
  tags.sort(proc(x, y: string): int = cmp(typeName(x), typeName(y)))
  for t in tags:
    result.add Preset(group: GenericGroup, label: typeName(t), tag: t, generic: true)
  for (group, cls, label, team, weapon, flags) in Characters:
    result.add Preset(group: group, label: label, detail: cls, tag: "CHAR", fields: @[
      ("OSD/Class", cls), ("OSD/Team", team), ("OSD/Weapon", weapon), ("OSD/Flags", flags)])
  for (cls, label) in Weapons:
    result.add Preset(group: "Weapons", label: label, detail: cls, tag: "WEAP",
                      fields: @[("OSD/Class", cls)])
  for (cls, label) in PowerUps:
    result.add Preset(group: "Power-ups", label: label, detail: cls, tag: "PWRU",
                      fields: @[("OSD/Class", cls)])
  for (cls, label) in Turrets:
    result.add Preset(group: "Turrets", label: label, detail: cls, tag: "TURR",
                      fields: @[("OSD/Class", cls), ("OSD/TargetedTeams", "Konoko")])
  for (group, cls, scale) in Particles:
    # Flags 12: created with the level, as the game's always-on particles are.
    var p = Preset(group: "Particles: " & group, label: cls, tag: "PART",
                   fields: @[("OSD/Class", cls), ("OSD/Flags", "12"), ("OSD/DecalScale", scale)])
    if cls in DecalTextures: p.oniFiles = @["TXMP" & DecalTextures[cls] & ".oni"]
    if not cls.startsWith("d_"): p.fields.add ("OSD/Tag", AutoStartTag)
    result.add p

proc presetXml*(p: Preset): string =
  ## The new object's element (Id and position are set when it's placed).
  if p.xml.len > 0: return p.xml
  let n = parseXml(Templates[p.tag])
  for (path, value) in p.fields:
    let e = n.xpath(path)
    if e != nil: e.setText(value)
  $n

proc matches*(p: Preset, filter: string): bool =
  ## filter is lower case.
  filter.len == 0 or filter in p.label.toLowerAscii or filter in p.detail.toLowerAscii or
    filter in p.group.toLowerAscii
