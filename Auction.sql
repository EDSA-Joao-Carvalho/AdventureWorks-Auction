USE AdventureWorks
GO

-- Auction schema setup
-- Idempotent: ensures that the Auction schema exists and if so does not recreate it
IF NOT EXISTS (
SELECT * FROM sys.schemas WHERE name = 'Auction')
BEGIN
	EXEC('CREATE SCHEMA Auction')
	PRINT('The Auction Schema was created successfully.')
END
ELSE
BEGIN 
	PRINT('The Auction Schema already exists.')
END
GO

-- Configuration table setup
-- Stores global configuration values for the auction that are configurable
IF NOT EXISTS (
SELECT * FROM sys.objects
	WHERE object_id = OBJECT_ID(N'[Auction].[Configuration]')
	AND type IN (N'U'))
BEGIN
	CREATE TABLE [Auction].[Configuration](
	[ConfigurationID] INT NOT NULL,
	[AuctionInitialDate] DATETIME NOT NULL,
	[AuctionEndDate] DATETIME NOT NULL,
	[MinBidAmount] MONEY NOT NULL,
	[MaxBidAmount] MONEY NOT NULL)
    
	INSERT INTO [Auction].[Configuration] 
        (ConfigurationID, AuctionInitialDate, AuctionEndDate, MinBidAmount, MaxBidAmount)
    VALUES 
        (1, '2025-11-16', '2025-11-30',0.05, 100.00);
    PRINT(N'The Auction.Configuration table was created successfully.');
END
ELSE
	PRINT(N'Auction.AConfiguration Table already exists');
GO

-- Auction table setup
-- Stores auction data per product following the business requeriments
IF NOT EXISTS (
SELECT * FROM sys.objects
	WHERE object_id = OBJECT_ID(N'[Auction].[Auction]')
	AND type IN (N'U'))
BEGIN
	CREATE TABLE [Auction].[Auction](
	[AuctionID] INT IDENTITY PRIMARY KEY NOT NULL,
	[ProductID] INT NOT NULL,
	[StartAuctionDate] DATETIME NOT NULL,
	[EndAuctionDate] DATETIME NULL,
	[ExpireDate] DATETIME NOT NULL,
	[InitialBidPrice] MONEY NOT NULL,
	[CurrentHighestBid] MONEY NULL,
	[CurrentHighestCustomerID] INT NULL,
	[ModifiedDate] DATETIME NULL,
	[StatusID] INT NOT NULL);
    PRINT(N'The Auction.Auction table was created successfully.');
END
ELSE
	PRINT(N'Auction.Auction Table already exists');

GO

-- Bid History table setup
-- Stores the bidding history for all bids placed by customers
IF NOT EXISTS (
SELECT * FROM sys.objects
	WHERE object_id = OBJECT_ID(N'[Auction].[BidHistory]')
	AND type IN (N'U'))
BEGIN
	CREATE TABLE [Auction].[BidHistory](
	[BidID] INT IDENTITY PRIMARY KEY NOT NULL,
	[AuctionID] INT NOT NULL,
	[CustomerID] INT NOT NULL,
	[BidAmount] MONEY NOT NULL,
	[BidTime] DATETIME NOT NULL);
    PRINT(N'The Auction.BidHistory table was created successfully.');
END
ELSE
	PRINT(N'Auction.BidHistory Table already exists');

GO

-- Status Type table setup
-- Defines all possible states for the products in auction and to control the auction itself
IF NOT EXISTS (
SELECT * FROM sys.objects
	WHERE object_id = OBJECT_ID(N'[Auction].[StatusType]')
	AND type IN (N'U'))
BEGIN
CREATE TABLE [Auction].[StatusType](
	[StatusID] INT IDENTITY(1,1) PRIMARY KEY NOT NULL,
	[StatusName] VARCHAR(30) NOT NULL UNIQUE);
	INSERT INTO [Auction].[StatusType]
		(StatusName)
	VALUES 
		('Cancelled'),
		('Active'),
		('Expired'),
		('Sold'),
		('Hold');
    PRINT(N'The Auction.StatusType table was created successfully.');
END
ELSE
	PRINT(N'Auction.StatusType Table already exists');
GO

-- Stored Procedure: Add Product to Auction
/* Adds a product to the auction if it follows these requirements:
	- has Stock;
	- only products that aren't in Auction yet (Status = Active or Hold);
	- only one active auction per product is allowed;
	- doesn't have sellEndDate/DiscontinuedDate
	- initial bid price: 75% of ListPrice when MakeFlag = 0, otherwise 50% of ListPrice; 
*/
CREATE OR ALTER PROCEDURE Auction.uspAddProductToAuction
@ProductID INT,
@ExpireDate DATETIME = NULL,
@InitialBidPrice MONEY = NULL
AS 
BEGIN
	BEGIN TRY
	DECLARE @ListPrice MONEY;
	DECLARE @MakeFlag BIT;
    DECLARE @AuctionEndDate DATETIME;

	DECLARE @AuctionInitialDate DATETIME
		SELECT @AuctionInitialDate = AuctionInitialDate
		FROM Auction.Configuration
		WHERE ConfigurationID = 1
		
	DECLARE @StartAuctionDate DATETIME;
		IF GETDATE() < @AuctionInitialDate
			SET @StartAuctionDate = @AuctionInitialDate;
		ELSE
			SET @StartAuctionDate = GETDATE();

	DECLARE @StatusID INT;
		IF @StartAuctionDate > GETDATE()
			SELECT @StatusID=StatusID
			FROM Auction.StatusType
			WHERE StatusName = 'Hold';
		ELSE 
			SELECT @StatusID=StatusID
			FROM Auction.StatusType
			WHERE StatusName = 'Active';

	DECLARE @ModifiedDate DATETIME = GETDATE();

	IF NOT EXISTS(
		SELECT 1 
		FROM Production.Product AS p
		INNER JOIN Production.WorkOrder AS wo
			ON p.ProductID = wo.ProductID
		WHERE p.ProductID = @ProductID 
			AND p.SellEndDate IS NULL 
			AND p.DiscontinuedDate IS NULL
			AND wo.StockedQty > 0)
	BEGIN
		;THROW 50001, 'Product does not exist.', 1;
	END;
	
	IF EXISTS(
		SELECT 1 
		FROM Auction.Auction a
		INNER JOIN Auction.StatusType st
		ON a.StatusID = st.StatusID 
		WHERE ProductID = @ProductID
		AND st.StatusName IN ('Active', 'Hold'))
		BEGIN
			;THROW 50002, 'The product is already being auctioned.', 1;
		END;	
	
	IF @ExpireDate IS NULL
		BEGIN
			SELECT @AuctionEndDate = AuctionEndDate
			FROM Auction.Configuration
			WHERE ConfigurationID = 1
				IF DATEADD(WEEK,1,GETDATE()) < @AuctionEndDate
					SET @ExpireDate = DATEADD(WEEK,1,GETDATE())
				ELSE 
					SET @ExpireDate = @AuctionEndDate
		END;
	
	IF @InitialBidPrice IS NULL
	BEGIN 
		SELECT 
		@MakeFlag = MakeFlag, 
		@ListPrice = ListPrice
		FROM Production.Product 
		WHERE ProductID = @ProductID;
		IF @MakeFlag = 0
			SET @InitialBidPrice = @ListPrice*0.75;
		ELSE 
			SET @InitialBidPrice = @ListPrice*0.5;
	END;

INSERT INTO Auction.Auction (ProductID, StartAuctionDate, ExpireDate, InitialBidPrice, ModifiedDate, StatusID)
VALUES (@ProductID, @StartAuctionDate, @ExpireDate, @InitialBidPrice, @ModifiedDate, @StatusID);
END TRY
BEGIN CATCH
    PRINT 'Error occurred: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
END;
GO

-- Stored Procedure: Try Bid Product
/* places a bid for a given product and customer if it follows these requirements:
	- only product with an 'Active' status can have bids placed;
	- first bid for the product must be equal to the initial bid price + minimum increment;
	- bids must be higher than the current highest bid;
	- bids can't exceed the product ListPrice;
	- use of transaction + lock to prevent overclashing of bids.
	*/
CREATE OR ALTER PROCEDURE Auction.uspTryBidProduct
@ProductID INT,
@CustomerID INT,
@BidAmount MONEY = NULL
AS
	BEGIN
	BEGIN TRY
	BEGIN TRANSACTION;
		DECLARE @CurrentAuctionID INT;
		DECLARE @Increment MONEY;
		DECLARE @MaxPrice MONEY;
		DECLARE @CurrentBid MONEY
		DECLARE @NewBid MONEY;

		SELECT @CurrentAuctionID = a.AuctionID
		FROM Auction.StatusType AS s WITH (UPDLOCK)
		INNER JOIN Auction.Auction AS a
			ON a.StatusID = s.StatusID
		WHERE s.StatusName = 'Active' 
			AND a.ProductID = @ProductID 
			AND a.ExpireDate > GETDATE() 
		
		IF @CurrentAuctionID IS NULL
		BEGIN
			;THROW 50003, 'The product does not have an auction active.', 1;
		END

		SELECT @Increment = MinBidAmount 
		FROM Auction.Configuration

		SELECT @MaxPrice = ListPrice 
		FROM Production.Product
		WHERE ProductID = @ProductID

		SELECT @CurrentBid = CurrentHighestBid
		FROM Auction.Auction
		WHERE AuctionID = @CurrentAuctionID

		IF @CurrentBid IS NULL 
		BEGIN 
			SELECT @CurrentBid =InitialBidPrice
			FROM Auction.Auction
			WHERE AuctionID = @CurrentAuctionID
		END;

		IF @BidAmount IS NULL
			SET @NewBid = @CurrentBid + @Increment
		ELSE
			SET @NewBid = @BidAmount

		IF @NewBid < @CurrentBid + @Increment
		BEGIN
			;THROW 50004, 'Bid does not respect the minimum increment.', 1;
		END

		IF @NewBid > @MaxPrice
		BEGIN
			;THROW 50005, 'Bid does not respect the maximum allowed.', 1;
		END;

	INSERT INTO Auction.BidHistory
	(AuctionID, CustomerID, BidAmount, BidTime)
	VALUES
	(@CurrentAuctionID, @CustomerID, @NewBid, GETDATE())

	UPDATE Auction.Auction
	SET CurrentHighestBid = @NewBid,
		CurrentHighestCustomerID = @CustomerID,
		ModifiedDate = GETDATE()
	WHERE AuctionID = @CurrentAuctionID

	COMMIT TRANSACTION;
	END TRY

BEGIN CATCH
   	IF @@TRANCOUNT > 0
		ROLLBACK TRANSACTION;
	PRINT 'The following error occurred:';
	PRINT ERROR_MESSAGE();
END CATCH;
END;
GO

-- Stored Procedure: Remove Product From Auction
/* Removes a product from auction if it is marked as 'Cancelled'*/
CREATE OR ALTER PROCEDURE Auction.uspRemoveProductFromAuction
@ProductID INT
AS
BEGIN
    BEGIN TRY
    BEGIN TRANSACTION

        DECLARE @AuctionID INT;
        DECLARE @CancelledStatusID INT;

        SELECT @AuctionID = a.AuctionID
        FROM Auction.Auction AS a
        INNER JOIN Auction.StatusType AS st
            ON a.StatusID = st.StatusID
        WHERE a.ProductID = @ProductID
            AND st.StatusName IN ('Active', 'Hold');

        IF @AuctionID IS NULL
        BEGIN
			;THROW 50001, 'The product is not currently listed.', 1;
        END;

        SELECT @CancelledStatusID = StatusID
        FROM Auction.StatusType
        WHERE StatusName = 'Cancelled';

        UPDATE Auction.Auction
        SET StatusID = @CancelledStatusID,
            EndAuctionDate = GETDATE(),
            ModifiedDate = GETDATE()
        WHERE AuctionID = @AuctionID;

    COMMIT TRANSACTION;

    PRINT 'The product has been successfully removed.';

    END TRY
   	BEGIN CATCH
       	IF @@TRANCOUNT > 0
           	ROLLBACK TRANSACTION;
       	PRINT 'The following error occurred:';
       	PRINT ERROR_MESSAGE();
   	END CATCH;
END;
GO

-- Stored Procedure: List Bids Offers History
/* Returns the bid history for a given customer */
CREATE OR ALTER PROCEDURE Auction.uspListBidsOffersHistory
@CustomerID INT,
@StartTime DATETIME,
@EndTime DATETIME,
@Active BIT = 1
AS
BEGIN 
	BEGIN TRY 
		SELECT bh.BidID,
               bh.AuctionID,
               bh.BidAmount,
               bh.BidTime,
               a.ProductID,
               a.StartAuctionDate,
               a.ExpireDate,
               st.StatusName
		From Auction.BidHistory as bh
		INNER JOIN Auction.Auction as a 
		ON bh.AuctionID = a.AuctionID
		INNER JOIN Auction.StatusType as st 
		ON st.StatusID = a.StatusID
		WHERE bh.CustomerID =@CustomerID 
		AND bh.BidTime BETWEEN @StartTime AND @EndTime
		AND (@Active = 0 OR st.StatusName IN ('Active','Hold'))
		ORDER BY bh.BidTime DESC;
	END TRY
	BEGIN CATCH
    PRINT 'Error occurred: ' + ERROR_MESSAGE();
    THROW;
	END CATCH;
END;
GO

-- Stored Procedure: Update Product Auction Status
/* Updates the auction status automatically:
	- If the Auction hasn't started all products with Active Status are set to Hold
	- If the Auction has started all products with Hold Status are set to Active
	- If the Auction has the max price of a product is reached, it's Status is set to Sold
	- If the Auction has reached it's end date then all products Status are set to either Sold (if at least 1 bid)
	or Expired (if no bids)
*/
CREATE OR ALTER PROCEDURE Auction.uspUpdateProductAuctionStatus 
AS 
BEGIN
BEGIN TRY

	UPDATE Auction.Auction
	SET StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Active'),
	ModifiedDate = GETDATE()
	WHERE StartAuctionDate<=GETDATE()
	AND ExpireDate>GETDATE()
	AND StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Hold');

	UPDATE Auction.Auction
	SET StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Hold'),
	ModifiedDate = GETDATE()
	WHERE StartAuctionDate>GETDATE()
	AND StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Active');

	UPDATE A
	SET A.StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Sold'),
	A.EndAuctionDate = A.ModifiedDate,
	A.ModifiedDate = GETDATE()
	FROM Auction.Auction A
    INNER JOIN Production.Product P
    ON P.ProductID = A.ProductID
	WHERE A.StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Active')
	AND A.CurrentHighestBid >= P.ListPrice - 0.04;

	UPDATE Auction.Auction
	SET StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Sold'),
	EndAuctionDate = ModifiedDate,
	ModifiedDate = GETDATE()
	WHERE ExpireDate < GETDATE()
	AND CurrentHighestBid IS NOT NULL
	AND StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Active');

	UPDATE Auction.Auction
	SET StatusID = (SELECT StatusID FROM Auction.StatusType WHERE StatusName = 'Expired'),
	EndAuctionDate = GETDATE(),
	ModifiedDate = GETDATE()
	WHERE ExpireDate<GETDATE()
	AND CurrentHighestBid IS NULL
	AND StatusID IN (SELECT StatusID FROM Auction.StatusType WHERE StatusName IN ('Active','Hold'));

END TRY
BEGIN CATCH
    PRINT 'Error occurred: ' + ERROR_MESSAGE();
    THROW;
END CATCH;
END;
GO