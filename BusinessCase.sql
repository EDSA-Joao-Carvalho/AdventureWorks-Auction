USE AdventureWorks
GO

DROP TABLE IF EXISTS #Sales;
DROP TABLE IF EXISTS #Location;

WITH Sales AS (
    SELECT 
        c.CustomerID,
        c.StoreID,
        c.PersonID,
        YEAR(oh.OrderDate) as SalesYear,
        oh.TotalDue
    FROM Sales.SalesOrderHeader AS oh
    INNER JOIN Sales.Customer AS c 
        ON oh.CustomerID = c.CustomerID
    WHERE oh.OrderDate >= '20230101'
)

SELECT *
INTO #Sales
FROM Sales;

WITH Location AS (
    SELECT 
        bea.BusinessEntityID,
        sp.StateProvinceCode,
        sp.Name AS StateProvinceName,
        a.City,
        at.AddressTypeID
    FROM Person.BusinessEntityAddress AS bea
    INNER JOIN Person.Address AS a 
        ON bea.AddressID = a.AddressID
    INNER JOIN Person.AddressType AS at 
        ON bea.AddressTypeID = at.AddressTypeID
    INNER JOIN Person.StateProvince AS sp 
        ON a.StateProvinceID = sp.StateProvinceID
    WHERE sp.CountryRegionCode = 'US'
)

SELECT *
INTO #Location
FROM Location;

WITH Top_30 AS (
SELECT TOP 30
    s.StoreID,
    L.StateProvinceCode,
    L.City,
    ROUND(SUM(CASE WHEN s.SalesYear = 2023 THEN s.TotalDue ELSE 0 END), 2) AS Total2023,
    ROUND(SUM(CASE WHEN s.SalesYear = 2024 THEN s.TotalDue ELSE 0 END), 2) AS Total2024,
    ROUND(SUM(CASE WHEN s.SalesYear = 2025 THEN s.TotalDue ELSE 0 END), 2) AS Total2025,
    ROUND(SUM(s.TotalDue), 2) AS TotalLast3Years
FROM #Sales AS s
INNER JOIN #Location L 
    ON s.StoreID = L.BusinessEntityID 
WHERE s.StoreID IS NOT NULL 
AND L.AddressTypeID = 3
GROUP BY s.StoreID, L.StateProvinceCode, L.City
ORDER BY TotalLast3Years DESC)

SELECT TOP 2
L.City, 
ROUND(SUM(s.TotalDue), 2) AS TotalLast3Years
FROM #Sales AS s
INNER JOIN #Location L 
    ON s.PersonID = L.BusinessEntityID 
WHERE s.StoreID IS NULL
AND L.City NOT IN (SELECT City FROM Top_30)
GROUP BY s.StoreID, L.StateProvinceCode, L.City
ORDER BY TotalLast3Years DESC

