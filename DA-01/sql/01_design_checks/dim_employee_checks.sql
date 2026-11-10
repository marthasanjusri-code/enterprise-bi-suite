/*
  dim_employee_checks.sql
  Design checks for dw.dim_employee (all employees, including salespeople
  and buyers): names, job titles, managers, salespeople, workforce mix,
  department sizes for the pay privacy rule, and leave hours.

  Source: AdventureWorks2025. Read-only.
  HR dates are shifted +4,017 days to the OLTP sales timeline.
  Each check is followed or preceded by its result and the decision it supports.
*/

-- =====================================================================
-- dim_employee: one row per employee (draft)
-- =====================================================================

USE AdventureWorks2025;
GO

-- 1. Names and person types: does every employee have a name?
SELECT  p.PersonType,
        COUNT(*)                                          AS employees,
        SUM(CASE WHEN p.FirstName IS NULL OR p.LastName IS NULL THEN 1 ELSE 0 END) AS missing_name,
        COUNT(DISTINCT p.FirstName + ' ' + p.LastName)    AS distinct_full_names
FROM HumanResources.Employee e
JOIN Person.Person p ON p.BusinessEntityID = e.BusinessEntityID
GROUP BY p.PersonType;

-- 2. Job titles and organization levels.
SELECT  COUNT(DISTINCT JobTitle)                              AS job_titles,
        SUM(CASE WHEN OrganizationLevel IS NULL THEN 1 ELSE 0 END) AS no_org_level,
        MIN(OrganizationLevel)                                AS min_level,
        MAX(OrganizationLevel)                                AS max_level
FROM HumanResources.Employee;

-- 3. Can each employee's manager be found from OrganizationNode
--    (the parent node in the hierarchy)? This would allow an org chart.
SELECT  COUNT(*)                                                AS employees,
        SUM(CASE WHEN e.OrganizationNode IS NULL THEN 1 ELSE 0 END) AS no_node,
        SUM(CASE WHEN m.BusinessEntityID IS NOT NULL THEN 1 ELSE 0 END) AS manager_found,
        SUM(CASE WHEN e.OrganizationNode IS NOT NULL
                  AND m.BusinessEntityID IS NULL THEN 1 ELSE 0 END) AS top_or_unmatched
FROM HumanResources.Employee e
LEFT JOIN HumanResources.Employee m
       ON m.OrganizationNode = e.OrganizationNode.GetAncestor(1);

-- 4. Salespeople: are all 17 employees, and what are their job titles?
SELECT  e.JobTitle,
        COUNT(*) AS salespeople
FROM Sales.SalesPerson s
JOIN HumanResources.Employee e ON e.BusinessEntityID = s.BusinessEntityID
GROUP BY e.JobTitle;

-- 5. Workforce mix at the sales data end (2025-06-30), after the shift:
--    gender, age band and salaried flag.
WITH emp AS (
    SELECT  Gender,
            SalariedFlag,
            DATEDIFF(year, DATEADD(day, 4017, BirthDate), '2025-06-30') AS age
    FROM HumanResources.Employee
)
SELECT  Gender,
        CASE WHEN age < 30 THEN 'Under 30'
             WHEN age < 40 THEN '30-39'
             WHEN age < 50 THEN '40-49'
             WHEN age < 60 THEN '50-59'
             ELSE               '60 and over' END AS age_band,
        SUM(CASE WHEN SalariedFlag = 1 THEN 1 ELSE 0 END) AS salaried,
        SUM(CASE WHEN SalariedFlag = 0 THEN 1 ELSE 0 END) AS hourly
FROM emp
GROUP BY Gender,
         CASE WHEN age < 30 THEN 'Under 30'
              WHEN age < 40 THEN '30-39'
              WHEN age < 50 THEN '40-49'
              WHEN age < 60 THEN '50-59'
              ELSE               '60 and over' END
ORDER BY Gender, age_band;

-- 6. Current department sizes: which departments have fewer than 5
--    employees (average pay would be hidden there)?
SELECT  d.GroupName,
        d.Name     AS department,
        COUNT(*)   AS employees,
        CASE WHEN COUNT(*) < 5 THEN 'pay hidden' ELSE 'pay shown' END AS pay_rule
FROM HumanResources.EmployeeDepartmentHistory h
JOIN HumanResources.Department d ON d.DepartmentID = h.DepartmentID
WHERE h.EndDate IS NULL
GROUP BY d.GroupName, d.Name
ORDER BY employees;

-- 7. Leave hours: ranges for vacation and sick leave.
SELECT  MIN(VacationHours)  AS min_vacation, MAX(VacationHours)  AS max_vacation,
        MIN(SickLeaveHours) AS min_sick,     MAX(SickLeaveHours) AS max_sick
FROM HumanResources.Employee;
GO
-- Results (03 Nov 2026):
--   1. 273 EM + 17 SP employees, all named, full names unique.
--   2. 67 job titles; organization level 1-4; 1 employee with no level.
--   3. 1 employee with no OrganizationNode; 283 managers found from the
--      parent node; 6 with a node but no matching manager. Most likely the
--      top employee has no node, so the 6 who report to the root find no
--      manager row. Manager can be derived for everyone: parent node, else
--      the top employee; the top employee has manager "Not applicable".
--   4. Salespeople: 14 Sales Representatives and 3 managers (European,
--      North American, Pacific Sales Manager). Confirms that 274, 285, 287
--      (no territory) are the regional sales managers.
--   5. 84 women, 206 men. Age bands at 2025-06-30: Under 30 89, 30-39 114,
--      40-49 61, 50-59 20, 60 and over 6. Salaried 52, hourly 238.
--   6. 16 departments. Fewer than 5 employees: Executive (2), Research and
--      Development (4), Tool Design (4). Average pay hidden there.
--      Risk: the Executive and R&D GROUP averages and the other departments'
--      averages are visible, so the hidden departments could be worked out
--      by subtraction.
--   7. Vacation hours 0-99, sick leave hours 20-80.
-- Decisions:
--   - manager_key derived as above (org chart = Should).
--   - Average pay rule (complementary suppression): show by department
--     group (all groups have 5 or more); show by department only when the
--     department has 5 or more AND no department in its group is hidden.