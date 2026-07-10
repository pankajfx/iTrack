"""Canonical seed values for the `form_options` MongoDB collection.

Source of truth for the Android app's form dropdowns. Values mirror the
lists hardcoded in templates/fe_new_installation.html so the mobile and web
forms stay consistent. To change a list in production, edit the collection
(or re-run scripts/seed_form_options.py after editing this file) — no APK
rebuild required.

Each option is {value, label}: `value` is what gets stored on the tracker
document, `label` is what the user sees (they differ only for VI today).
"""


def _opts(*values):
    return [{'value': v, 'label': v} for v in values]


DEFAULT_FORM_OPTIONS = {
    'customers': _opts(
        'AGS-AXIS', 'AGS-MOF-SBI-TOM-2', 'AIMIL-Ltd', 'C-EDGE',
        'CANARY-AUTOMATION-LTD', 'CMS-ICICI', 'CMS-SBI-TOM', 'ENCARDIO-RITE',
        'EPS-UBI', 'FSS-UJJIVAN', 'HITACHI-HDFC-Bank', 'HITACHI-INDUSIND-Bank',
        'HITACHI-SBI-TOM2-PILOT-SITE-20', 'Hitachi-Axis', 'Hitachi-ICICI',
        'Hitachi-SBI-TOM', 'Hitachi-SBI-TOM-2-MOF', 'Hitachi-WLA', 'ISR',
        'NCR-BOB', 'NCR-SBI-TOM-2', 'TEMFLO-E-BIZ', 'TSI-SBI', 'Writer-ICICI',
        'nelco',
    ),
    'sim_providers': [
        {'value': 'Airtel', 'label': 'Airtel'},
        {'value': 'Jio', 'label': 'Jio'},
        {'value': 'VI', 'label': 'VI (Vodafone Idea)'},
        {'value': 'BSNL', 'label': 'BSNL'},
    ],
    'router_types': _opts('PI-15', 'PI-11', 'PI-24'),
    'router_makes': _opts('Made in India', 'Made in China', 'Made in Taiwan'),
}
