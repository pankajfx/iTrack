# Theme Configuration for SDWAN Tracker
# Role-based theme switching - each role gets its own distinct theme

# ============================================================================
# ROLE-BASED THEME MAPPING - Assign themes to each role
# ============================================================================
ROLE_THEMES = {
    'FIELD_ENGINEER': 'ocean_depths',           # fixed
    'FIELD_ENGINEER_GROUP': 'ocean_depths',  #fixed
    'FIELD_SUPPORT': 'royal_purple',          # FS - Forest green
    'FIELD_SUPPORT_GROUP': 'royal_purple',   # fix royal_purple
    'NOC_SUPPORT': 'azure_blue_1',  #fixed
    'ANALYTICS': 'azure_blue',               # Analytics - Azure blue
}

# Fallback themes for backward compatibility
ACTIVE_FE_THEME = 'deep_teal'
ACTIVE_NOC_THEME = 'steel_gray'

# ============================================================================
# FE THEMES - Field Engineer Color Schemes
# ============================================================================
FE_THEMES = {
    'sunset_coral': {
        'name': 'Sunset Coral',
        'description': 'Warm, energetic coral and peach gradient - friendly and approachable',
        'gradient_from': '#f9a470',  # Coral/Peach
        'gradient_to': '#bc556f',    # Rose/Pink
        'accent': '#f9a470',
        'hover': '#f89560',
        'focus_ring': '#f9a470',
        'badge_bg': '#fef3f0',
        'badge_text': '#bc556f',
        'button_bg': '#f9a470',
        'button_hover': '#f89560',
    },
    
    'ocean_breeze': {
        'name': 'Ocean Breeze',
        'description': 'Calm blue and turquoise - professional and trustworthy',
        'gradient_from': '#4facfe',  # Sky Blue
        'gradient_to': '#00f2fe',    # Cyan
        'accent': '#4facfe',
        'hover': '#3f9cee',
        'focus_ring': '#4facfe',
        'badge_bg': '#eff8ff',
        'badge_text': '#2563eb',
        'button_bg': '#4facfe',
        'button_hover': '#3f9cee',
    },
    
    'forest_mint': {
        'name': 'Forest Mint',
        'description': 'Fresh green and mint - natural and calming',
        'gradient_from': '#56ab2f',  # Forest Green
        'gradient_to': '#a8e063',    # Lime Green
        'accent': '#56ab2f',
        'hover': '#4a9628',
        'focus_ring': '#56ab2f',
        'badge_bg': '#f0fdf4',
        'badge_text': '#15803d',
        'button_bg': '#56ab2f',
        'button_hover': '#4a9628',
    },
    
    'royal_purple': {
        'name': 'Royal Purple',
        'description': 'Elegant purple and violet - sophisticated and premium',
        'gradient_from': '#667eea',  # Purple
        'gradient_to': '#764ba2',    # Deep Purple
        'accent': '#667eea',
        'hover': '#5568d3',
        'focus_ring': '#667eea',
        'badge_bg': '#faf5ff',
        'badge_text': '#7c3aed',
        'button_bg': '#667eea',
        'button_hover': '#5568d3',
    },
    
    'warm_amber': {
        'name': 'Warm Amber',
        'description': 'Golden amber and orange - energetic and optimistic',
        'gradient_from': '#f7971e',  # Orange
        'gradient_to': '#ffd200',    # Golden Yellow
        'accent': '#f7971e',
        'hover': '#e8880e',
        'focus_ring': '#f7971e',
        'badge_bg': '#fffbeb',
        'badge_text': '#d97706',
        'button_bg': '#f7971e',
        'button_hover': '#e8880e',
    },
    
    'cool_slate': {
        'name': 'Cool Slate',
        'description': 'Modern gray and blue-gray - clean and professional',
        'gradient_from': '#485563',  # Dark Slate
        'gradient_to': '#29323c',    # Charcoal
        'accent': '#485563',
        'hover': '#3a4552',
        'focus_ring': '#485563',
        'badge_bg': '#f8fafc',
        'badge_text': '#475569',
        'button_bg': '#485563',
        'button_hover': '#3a4552',
    },
    
    'pacific_blue': {
        'name': 'Pacific Blue',
        'description': 'UCLA blue and ocean tones - vibrant and energetic',
        'gradient_from': '#2774AE',  # UCLA Blue
        'gradient_to': '#0076B6',    # Pacific Blue
        'accent': '#2774AE',
        'hover': '#1e5a8a',
        'focus_ring': '#2774AE',
        'badge_bg': '#eff6ff',
        'badge_text': '#1e40af',
        'button_bg': '#2774AE',
        'button_hover': '#1e5a8a',
    },
    
    'aqua_marine': {
        'name': 'Aqua Marine',
        'description': 'Turquoise and teal blend - refreshing and modern',
        'gradient_from': '#39A78D',  # Turquoise
        'gradient_to': '#39A78D',    # Jungle Green
        'accent': '#0093AF',
        'hover': '#007a8f',
        'focus_ring': '#0093AF',
        'badge_bg': '#f0fdfa',
        'badge_text': '#0f766e',
        'button_bg': '#0093AF',
        'button_hover': '#007a8f',
    },
    
    'sage_green': {
        'name': 'Sage Green',
        'description': 'Soft sage and mint - calming and natural',
        'gradient_from': '#39A78D',  # Sage
        'gradient_to': '#39A78D',    # Jungle Green
        'accent': '#39A78D',
        'hover': '#6a9580',
        'focus_ring': '#39A78D',
        'badge_bg': '#f0fdf4',
        'badge_text': '#15803d',
        'button_bg': '#39A78D',
        'button_hover': '#6a9580',
    },
    
    'deep_teal': {
        'name': 'Deep Teal',
        'description': 'Rich teal and dark cyan - sophisticated and bold',
        'gradient_from': '#007A74',  # Pine Green
        'gradient_to': '#008B8B',    # Dark Cyan
        'accent': '#007A74',
        'hover': '#00615d',
        'focus_ring': '#007A74',
        'badge_bg': '#f0fdfa',
        'badge_text': '#115e59',
        'button_bg': '#007A74',
        'button_hover': '#00615d',
    },
    
    'ocean_depths': {
        'name': 'Ocean Depths',
        'description': 'Deep ocean blues - mysterious and professional',
        'gradient_from': '#006D6F',  # Skobeloff
        'gradient_to': '#004953',    # Deep Jungle Green
        'accent': '#006D6F',
        'hover': '#005558',
        'focus_ring': '#006D6F',
        'badge_bg': '#ecfeff',
        'badge_text': '#155e63',
        'button_bg': '#006D6F',
        'button_hover': '#005558',
    },
    
    'coral_sunset': {
        'name': 'Coral Sunset',
        'description': 'Warm coral and terracotta - inviting and energetic',
        'gradient_from': '#A45A52',  # Redwood
        'gradient_to': '#E97451',    # Burnt Sienna
        'accent': '#A45A52',
        'hover': '#8a4a43',
        'focus_ring': '#A45A52',
        'badge_bg': '#fef2f2',
        'badge_text': '#991b1b',
        'button_bg': '#A45A52',
        'button_hover': '#8a4a43',
    },
    
    'vibrant_orange': {
        'name': 'Vibrant Orange',
        'description': 'Bold orange - high energy and attention-grabbing',
        'gradient_from': '#FF5800',  # International Orange
        'gradient_to': '#E97451',    # Burnt Sienna
        'accent': '#FF5800',
        'hover': '#e04f00',
        'focus_ring': '#FF5800',
        'badge_bg': '#fff7ed',
        'badge_text': '#c2410c',
        'button_bg': '#FF5800',
        'button_hover': '#e04f00',
    },
    
    'royal_violet': {
        'name': 'Royal Violet',
        'description': 'Deep purple and violet - luxurious and creative',
        'gradient_from': '#5A4FCF',  # Iris
        'gradient_to': '#5B3256',    # Dark Purple
        'accent': '#5A4FCF',
        'hover': '#4a3fb5',
        'focus_ring': '#5A4FCF',
        'badge_bg': '#faf5ff',
        'badge_text': '#6b21a8',
        'button_bg': '#5A4FCF',
        'button_hover': '#4a3fb5',
    },
    
    'magenta_rose': {
        'name': 'Magenta Rose',
        'description': 'Vibrant magenta and rose - bold and feminine',
        'gradient_from': '#C54B8C',  # Mulberry
        'gradient_to': '#8E3A59',    # Twilight Lavender
        'accent': '#C54B8C',
        'hover': '#a83d73',
        'focus_ring': '#C54B8C',
        'badge_bg': '#fdf2f8',
        'badge_text': '#9f1239',
        'button_bg': '#C54B8C',
        'button_hover': '#a83d73',
    },
}

# ============================================================================
# NOC THEMES - Network Operations Center Color Schemes
# ============================================================================
NOC_THEMES = {
    'teal_cyan': {
        'name': 'Teal Cyan',
        'description': 'Current theme - professional teal and cyan',
        'gradient_from': '#14b8a6',  # Teal
        'gradient_to': '#06b6d4',    # Cyan
        'accent': '#14b8a6',
        'hover': '#0d9488',
        'focus_ring': '#14b8a6',
        'badge_bg': '#f0fdfa',
        'badge_text': '#0f766e',
        'button_bg': '#14b8a6',
        'button_hover': '#0d9488',
    },
    
    'deep_blue': {
        'name': 'Deep Blue',
        'description': 'Classic corporate blue - trustworthy and stable',
        'gradient_from': '#1e3a8a',  # Navy Blue
        'gradient_to': '#3b82f6',    # Blue
        'accent': '#3b82f6',
        'hover': '#2563eb',
        'focus_ring': '#3b82f6',
        'badge_bg': '#eff6ff',
        'badge_text': '#1e40af',
        'button_bg': '#3b82f6',
        'button_hover': '#2563eb',
    },
    
    'emerald_green': {
        'name': 'Emerald Green',
        'description': 'Vibrant emerald - fresh and modern',
        'gradient_from': '#059669',  # Emerald
        'gradient_to': '#10b981',    # Green
        'accent': '#059669',
        'hover': '#047857',
        'focus_ring': '#059669',
        'badge_bg': '#f0fdf4',
        'badge_text': '#065f46',
        'button_bg': '#059669',
        'button_hover': '#047857',
    },
    
    'midnight_purple': {
        'name': 'Midnight Purple',
        'description': 'Deep purple and indigo - premium and sophisticated',
        'gradient_from': '#4c1d95',  # Deep Purple
        'gradient_to': '#6366f1',    # Indigo
        'accent': '#6366f1',
        'hover': '#4f46e5',
        'focus_ring': '#6366f1',
        'badge_bg': '#faf5ff',
        'badge_text': '#6b21a8',
        'button_bg': '#6366f1',
        'button_hover': '#4f46e5',
    },
    
    'steel_gray': {
        'name': 'Steel Gray',
        'description': 'Industrial steel gray - serious and technical',
        'gradient_from': '#374151',  # Gray
        'gradient_to': '#6b7280',    # Light Gray
        'accent': '#6b7280',
        'hover': '#4b5563',
        'focus_ring': '#6b7280',
        'badge_bg': '#f9fafb',
        'badge_text': '#374151',
        'button_bg': '#6b7280',
        'button_hover': '#4b5563',
    },
    
    'crimson_red': {
        'name': 'Crimson Red',
        'description': 'Bold crimson and red - urgent and attention-grabbing',
        'gradient_from': '#dc2626',  # Red
        'gradient_to': '#ef4444',    # Light Red
        'accent': '#dc2626',
        'hover': '#b91c1c',
        'focus_ring': '#dc2626',
        'badge_bg': '#fef2f2',
        'badge_text': '#991b1b',
        'button_bg': '#dc2626',
        'button_hover': '#b91c1c',
    },
    
    'azure_blue': {
        'name': 'Azure Blue',
        'description': 'Bright azure and pacific blue - clear and focused',
        'gradient_from': '#0076B6',  # Pacific Blue
        'gradient_to': '#0093AF',    # Turquoise
        'accent': '#0076B6',
        'hover': '#005f95',
        'focus_ring': '#0076B6',
        'badge_bg': '#eff6ff',
        'badge_text': '#1e40af',
        'button_bg': '#0076B6',
        'button_hover': '#005f95',
    },

    'azure_blue_1': {
        'name': 'Azure Blue',
        'description': 'Bright azure and pacific blue - clear and focused',
        'gradient_from': '#0076B6',  # Pacific Blue
        'gradient_to': '#0076B6',    # Turquoise
        'accent': '#0076B6',
        'hover': '#0076B6',
        'focus_ring': '#0076B6',
        'badge_bg': '#eff6ff',
        'badge_text': '#1e40af',
        'button_bg': '#0076B6',
        'button_hover': '#005f95',
    },
    
    'jungle_teal': {
        'name': 'Jungle Teal',
        'description': 'Jungle green and teal - natural and balanced',
        'gradient_from': '#29AB87',  # Jungle Green
        'gradient_to': '#007A74',    # Pine Green
        'accent': '#29AB87',
        'hover': '#218a6d',
        'focus_ring': '#29AB87',
        'badge_bg': '#f0fdf4',
        'badge_text': '#065f46',
        'button_bg': '#29AB87',
        'button_hover': '#218a6d',
    },
    
    'dark_cyan': {
        'name': 'Dark Cyan',
        'description': 'Deep cyan and teal - technical and precise',
        'gradient_from': '#008B8B',  # Dark Cyan
        'gradient_to': '#006D6F',    # Skobeloff
        'accent': '#008B8B',
        'hover': '#006f6f',
        'focus_ring': '#008B8B',
        'badge_bg': '#ecfeff',
        'badge_text': '#155e63',
        'button_bg': '#008B8B',
        'button_hover': '#006f6f',
    },
    
    'midnight_ocean': {
        'name': 'Midnight Ocean',
        'description': 'Deep ocean tones - serious and commanding',
        'gradient_from': '#004953',  # Deep Jungle Green
        'gradient_to': '#006D6F',    # Skobeloff
        'accent': '#004953',
        'hover': '#003842',
        'focus_ring': '#004953',
        'badge_bg': '#ecfeff',
        'badge_text': '#164e63',
        'button_bg': '#004953',
        'button_hover': '#003842',
    },
    
    'burnt_orange': {
        'name': 'Burnt Orange',
        'description': 'Warm burnt orange - energetic and bold',
        'gradient_from': '#E97451',  # Burnt Sienna
        'gradient_to': '#FF5800',    # International Orange
        'accent': '#E97451',
        'hover': '#d15f3d',
        'focus_ring': '#E97451',
        'badge_bg': '#fff7ed',
        'badge_text': '#c2410c',
        'button_bg': '#E97451',
        'button_hover': '#d15f3d',
    },
    
    'iris_purple': {
        'name': 'Iris Purple',
        'description': 'Vibrant iris purple - creative and innovative',
        'gradient_from': '#5A4FCF',  # Iris
        'gradient_to': '#C54B8C',    # Mulberry
        'accent': '#5A4FCF',
        'hover': '#4a3fb5',
        'focus_ring': '#5A4FCF',
        'badge_bg': '#faf5ff',
        'badge_text': '#6b21a8',
        'button_bg': '#5A4FCF',
        'button_hover': '#4a3fb5',
    },
    
    'twilight_magenta': {
        'name': 'Twilight Magenta',
        'description': 'Deep magenta and twilight - dramatic and bold',
        'gradient_from': '#8E3A59',  # Twilight Lavender
        'gradient_to': '#5B3256',    # Dark Purple
        'accent': '#8E3A59',
        'hover': '#752f49',
        'focus_ring': '#8E3A59',
        'badge_bg': '#fdf2f8',
        'badge_text': '#9f1239',
        'button_bg': '#8E3A59',
        'button_hover': '#752f49',
    },
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
def get_theme_for_role(role):
    """Get theme configuration for a specific role"""
    theme_key = ROLE_THEMES.get(role)
    if not theme_key:
        # Fallback to default themes
        return get_active_fe_theme()
    
    # Try FE themes first, then NOC themes
    theme = FE_THEMES.get(theme_key) or NOC_THEMES.get(theme_key)
    if not theme:
        return get_active_fe_theme()
    
    return theme

def get_active_fe_theme():
    """Get the currently active FE theme configuration"""
    return FE_THEMES.get(ACTIVE_FE_THEME, FE_THEMES['sunset_coral'])

def get_active_noc_theme():
    """Get the currently active NOC theme configuration"""
    return NOC_THEMES.get(ACTIVE_NOC_THEME, NOC_THEMES['teal_cyan'])

def get_theme_css_vars(theme_config):
    """Convert theme config to CSS variables"""
    return f"""
        --gradient-from: {theme_config['gradient_from']};
        --gradient-to: {theme_config['gradient_to']};
        --accent: {theme_config['accent']};
        --hover: {theme_config['hover']};
        --focus-ring: {theme_config['focus_ring']};
        --badge-bg: {theme_config['badge_bg']};
        --badge-text: {theme_config['badge_text']};
        --button-bg: {theme_config['button_bg']};
        --button-hover: {theme_config['button_hover']};
    """

def list_all_themes():
    """List all available themes"""
    print("\n" + "="*80)
    print("AVAILABLE FE THEMES (Field Engineer)")
    print("="*80)
    for key, theme in FE_THEMES.items():
        active = " [ACTIVE]" if key == ACTIVE_FE_THEME else ""
        print(f"\n{key}{active}")
        print(f"  Name: {theme['name']}")
        print(f"  Description: {theme['description']}")
        print(f"  Colors: {theme['gradient_from']} → {theme['gradient_to']}")
    
    print("\n" + "="*80)
    print("AVAILABLE NOC THEMES (Network Operations Center)")
    print("="*80)
    for key, theme in NOC_THEMES.items():
        active = " [ACTIVE]" if key == ACTIVE_NOC_THEME else ""
        print(f"\n{key}{active}")
        print(f"  Name: {theme['name']}")
        print(f"  Description: {theme['description']}")
        print(f"  Colors: {theme['gradient_from']} → {theme['gradient_to']}")
    print("\n" + "="*80)

if __name__ == '__main__':
    list_all_themes()
