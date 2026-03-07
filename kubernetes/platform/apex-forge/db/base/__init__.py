"""
ApexForge - Continuous Threat Exposure Management platform
"""

__version__ = "13.0.0"
__author__ = "Marco Milano"
__description__ = "Personal infrastructure watchdog: servers and sites monitored via Nmap, uptime, SSL, and CVE alerts"

from apex_forge.risk_scorer import RiskScorer
from apex_forge.db import get_pg_pool

__all__ = ["RiskScorer", "get_pg_pool"]