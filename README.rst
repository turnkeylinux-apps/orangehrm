OrangeHRM - Human Resources management
======================================

`OrangeHRM`_ is an open source HRM (HRIS) solution for small and medium
sized companies used by more than 1 million users worldwide.
Functionality includes employee information management, employee absence
management, recruitment management, employee performance evaluation and
many other HR management tools.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- OrangeHRM configurations:
   
   - Installed from upstream source code to /var/www/orangehrm

- SSL support out of the box.
- `Adminer`_ administration frontend for MySQL (listening on port
  12322 - uses SSL).
- Postfix MTA (bound to localhost) to allow sending of email (e.g.,
  password recovery).
- Webmin modules for configuring Apache2, PHP, MySQL and Postfix.

Credentials *(passwords set at first boot)*
-------------------------------------------

-  Webmin, SSH, MySQL, phpMyAdmin: username **root**
-  OrangeHRM: username **admin**


.. _OrangeHRM: http://www.orangehrm.com
.. _TurnKey Core: http://www.turnkeylinux.org/core
.. _Adminer: http://www.adminer.org/
