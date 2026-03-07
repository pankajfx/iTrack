---
inclusion: always
---

# Product Overview

SDWAN Installation Tracker is a Flask-based web application for tracking SD-WAN installation progress across field operations. The system provides role-based dashboards for Field Engineers (FE), Network Operations Center (NOC) teams, and Analytics users.

## Core Purpose

Track the complete lifecycle of SD-WAN installations from site creation through SIM activation, Zero Touch Provisioning (ZTP), coordination, and final handshake sign-off (HSO).

## Key User Roles

- **Field Engineer (FE)**: Creates trackers at customer sites, manages on-site installation progress (mobile-optimized)
- **NOC Support (NS)**: Backend support for SIM activation, ZTP configuration/execution, HSO approval (desktop-optimized)
- **Analytics**: View performance metrics, KPIs, and drill-down reports
- **Hierarchical Roles**: Field Engineer Groups (FEG), Field Support (FS), Field Support Groups (FSG), NOC Support Groups (NSG) for management oversight

## Installation Workflow

1. FE creates tracker with customer details, router info, SIM data
2. NOC assigns tracker to NS operator
3. NS activates SIM cards (SIM1, SIM2)
4. NS verifies ZTP configuration
5. FE or NS performs ZTP execution
6. NS marks ready for coordination (unlocks chat)
7. FE submits HSO documentation
8. NS approves HSO → Installation complete

## Key Features

- Real-time installation tracking with event history
- Role-based access control with hierarchical visibility
- Mobile-first FE dashboard, desktop-optimized NOC dashboard
- Interactive analytics with multi-level drill-down
- Chat system for FE-NS coordination (unlocks after ZTP)
- Image capture and document upload
- Customizable themes per role
