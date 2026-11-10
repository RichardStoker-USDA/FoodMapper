import XCTest
@testable import FoodMapper

final class FDCImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("foodmapper-fdc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: folder.appendingPathComponent(name))
    }

    private func writeBundle() throws {
        try write("food.csv", #"""
        "fdc_id","data_type","description","food_category_id","publication_date"
        "100","sr_legacy_food","Broccoli, raw","11","2019-04-01"
        "101","foundation_food","Soup, chicken noodle, canned, ""ready-to-serve""","6","2020-10-30"
        "102","sample_food","Broccoli sample 4","11","2020-10-30"
        "103","sr_legacy_food","Water, tap","14","2019-04-01"
        "100","sr_legacy_food","Duplicate identifier","11","2019-04-01"
        "104","survey_fndds_food","Milk,
        whole","9602","2024-10-31"

        """#)
        try write("food_category.csv", #"""
        "id","code","description"
        "11","1100","Vegetables and Vegetable Products"
        "6","0600","Soups, Sauces, and Gravies"
        "14","1400","Beverages"

        """#)
        try write("wweia_food_category.csv", #"""
        "wweia_food_category","wweia_food_category_description"
        "9602","Milk, whole"

        """#)
        try write("food_nutrient.csv", #"""
        "id","fdc_id","nutrient_id","amount","data_points"
        "1","100","1008","34","3"
        "2","100","1003","2.82","3"
        "3","100","1093","33","3"
        "4","100","1087","47","3"
        "5","101","2048","25","1"
        "6","101","2047","24","1"
        "7","101","1093","343","1"
        "8","102","1008","31","1"
        "9","999","1008","500","1"
        "10","104","1008","61",""
        "11","104","1063","4.8",""
        "12","104","2000","5.05",""
        "13","100","1005","not a number","3"

        """#)
    }

    private func convert() throws -> (FDCBundleImportSummary, [[String]]) {
        let output = folder.appendingPathComponent("targets.csv")
        let summary = try FDCBundleImporter.convert(bundle: folder, to: output)
        let content = try String(contentsOf: output, encoding: .utf8)
        return (summary, try CSVParser.parseRecords(content: content, delimiter: ","))
    }

    func testBundleBecomesOneRowPerFoodWithNutrients() throws {
        try writeBundle()
        let (summary, records) = try convert()
        XCTAssertEqual(records[0], FDCBundleImporter.outputColumns)
        XCTAssertEqual(records[0], [
            "fdc_id", "description", "data_type", "category",
            "energy_kcal", "protein_g", "fat_g", "carbohydrate_g", "fiber_g", "sugars_g", "sodium_mg",
        ])
        XCTAssertEqual(records.count, 5)
        XCTAssertEqual(records[1], ["100", "Broccoli, raw", "sr_legacy_food", "Vegetables and Vegetable Products", "34", "2.82", "", "", "", "", "33"])
        // Atwater general energy (2047) is preferred over specific (2048) when 1008 is absent.
        XCTAssertEqual(records[2], ["101", "Soup, chicken noodle, canned, \"ready-to-serve\"", "foundation_food", "Soups, Sauces, and Gravies", "24", "", "", "", "", "", "343"])
        // A food with no reported nutrient keeps empty cells. Nothing becomes zero.
        XCTAssertEqual(records[3], ["103", "Water, tap", "sr_legacy_food", "Beverages", "", "", "", "", "", "", ""])
        // A quoted description may contain a line break; total sugars (2000) wins over 1063.
        XCTAssertEqual(records[4], ["104", "Milk,\nwhole", "survey_fndds_food", "Milk, whole", "61", "", "", "", "", "5.05", ""])

        XCTAssertEqual(summary.foods, 4)
        XCTAssertEqual(summary.excludedFoods, 2)
        XCTAssertEqual(summary.foodsWithoutNutrients, 1)
        XCTAssertEqual(summary.foodsByDataType, ["sr_legacy_food": 2, "foundation_food": 1, "survey_fndds_food": 1])
        XCTAssertEqual(summary.skippedNutrientIDs, [])
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("targets.csv").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testRejectsFoldersThatAreNotFDCBundles() throws {
        XCTAssertThrowsError(try convert()) { XCTAssertEqual($0 as? FDCBundleImportError, .missingFile("food.csv")) }
        try write("food.csv", "\"fdc_id\",\"description\"\n\"1\",\"x\"\n")
        XCTAssertThrowsError(try convert()) { XCTAssertEqual($0 as? FDCBundleImportError, .missingFile("food_nutrient.csv")) }
        try write("food_nutrient.csv", "\"fdc_id\",\"nutrient_id\",\"amount\"\n")
        XCTAssertThrowsError(try convert()) {
            XCTAssertEqual($0 as? FDCBundleImportError, .missingColumn(file: "food.csv", column: "data_type"))
        }
        try write("food.csv", "\"fdc_id\",\"data_type\",\"description\"\n\"1\",\"sample_food\",\"x\"\n")
        XCTAssertThrowsError(try convert()) { XCTAssertEqual($0 as? FDCBundleImportError, .noFoods) }
        try write("food.csv", "")
        XCTAssertThrowsError(try convert()) {
            XCTAssertEqual($0 as? FDCBundleImportError, .missingColumn(file: "food.csv", column: "fdc_id"))
        }
        try write("food.csv", "\"fdc_id\",\"data_type\",\"description\"\n\"1\",\"sr_legacy_food\",\"never closed\n")
        XCTAssertThrowsError(try convert()) {
            guard case .unreadableFile(name: "food.csv", reason: _)? = $0 as? FDCBundleImportError else {
                return XCTFail("expected an unreadable file error, got \($0)")
            }
        }
    }

    func testNutrientUnitsFromTheBundleAreChecked() throws {
        try writeBundle()
        // This bundle reports sodium (1093) in grams, so the sodium_mg column must stay empty.
        try write("nutrient.csv", #"""
        "id","name","unit_name","nutrient_nbr","rank"
        "1008","Energy","KCAL","208","300.0"
        "1003","Protein","g","203","600.0"
        "1093","Sodium, Na","G","307","5800.0"

        """#)
        let (summary, records) = try convert()
        XCTAssertEqual(summary.skippedNutrientIDs, ["1093"])
        XCTAssertEqual(records[1], ["100", "Broccoli, raw", "sr_legacy_food", "Vegetables and Vegetable Products", "34", "2.82", "", "", "", "", ""])
    }

    /// FNDDS downloads write the legacy nutrient number (208) where the others write the ID (1008).
    func testNutrientNumbersAreAcceptedInPlaceOfIDs() throws {
        try write("food.csv", #"""
        "fdc_id","data_type","description","food_category_id","publication_date"
        "2705384","survey_fndds_food","Milk, NFS","1004","2022-10-28"

        """#)
        try write("food_nutrient.csv", #"""
        "id","fdc_id","nutrient_id","amount"
        "1","2705384","208","51"
        "2","2705384","203","3.33"
        "3","2705384","269","4.89"
        "4","2705384","307","39"
        "5","2705384","301","125"

        """#)
        let expected = ["2705384", "Milk, NFS", "survey_fndds_food", "", "51", "3.33", "", "", "", "4.89", "39"]
        XCTAssertEqual(try convert().1[1], expected)

        // With the bundle's own nutrient table, the number comes from that table.
        try write("nutrient.csv", #"""
        "id","name","unit_name","nutrient_nbr","rank"
        "1008","Energy","KCAL","208","300.0"
        "1003","Protein","G","203","600.0"
        "2000","Total Sugars","G","269","1510.0"
        "1093","Sodium, Na","MG","307","5800.0"
        "1087","Calcium, Ca","MG","301","5300.0"

        """#)
        XCTAssertEqual(try convert().1[1], expected)

        // A number that this bundle uses as another nutrient's ID is not treated as an alias.
        try write("nutrient.csv", #"""
        "id","name","unit_name","nutrient_nbr","rank"
        "1008","Energy","KCAL","208","300.0"
        "208","Something else","MG","9999","1.0"

        """#)
        XCTAssertEqual(try convert().1[1][4], "")
    }

    func testBrandedFoodsTakeTheirCategoryFromTheBrandedTable() throws {
        try write("food.csv", #"""
        "fdc_id","data_type","description","food_category_id","publication_date"
        "500","branded_food","OAT CEREAL","","2024-04-18"
        "501","branded_food","  Padded name ","","2024-04-18"

        """#)
        try write("branded_food.csv", #"""
        "fdc_id","brand_owner","branded_food_category"
        "500","Example Mills","Cereal"
        "999","Other","Snacks"

        """#)
        try write("food_nutrient.csv", "\"id\",\"fdc_id\",\"nutrient_id\",\"amount\"\n\"1\",\"500\",\"1008\",\"375\"\n")
        let (summary, records) = try convert()
        XCTAssertEqual(records[1], ["500", "OAT CEREAL", "branded_food", "Cereal", "375", "", "", "", "", "", ""])
        // A quoted source value keeps its spaces through the table FoodMapper writes.
        XCTAssertEqual(records[2][1], "  Padded name ")
        XCTAssertEqual(records[2][3], "")
        XCTAssertEqual(FDCBundleImporter.suggestedName(
            folder: URL(fileURLWithPath: "/x/FoodData_Central_branded_food_csv_2024-04-18"), summary: summary
        ), "FDC Branded 2024-04-18")
    }

    func testFoodLimitAndTemporaryFolder() throws {
        try writeBundle()
        XCTAssertThrowsError(try FDCBundleImporter.convert(bundle: folder, to: folder.appendingPathComponent("out.csv"), maximumFoods: 3)) {
            XCTAssertEqual($0 as? FDCBundleImportError, .tooManyFoods(3))
        }
        let root = folder.appendingPathComponent("temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let converted = try FDCBundleImporter.convertToTemporaryFile(bundle: folder, temporaryRoot: root)
        let directory = converted.output.deletingLastPathComponent()
        XCTAssertEqual(directory.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(converted.summary.foods, 4)
        XCTAssertEqual(FDCBundleImporter.suggestedName(folder: folder, summary: converted.summary), "FDC")
        // Digits inside another token, such as a random identifier, are not a release date.
        XCTAssertEqual(FDCBundleImporter.suggestedName(
            folder: URL(fileURLWithPath: "/x/import-1B2A9899-3745-2019-11AB-0123456789AB"), summary: converted.summary
        ), "FDC")
        XCTAssertEqual(FDCBundleImporter.suggestedName(
            folder: URL(fileURLWithPath: "/x/FoodData_Central_sr_legacy_food_csv_2018-04"),
            summary: FDCBundleImportSummary(foods: 1, excludedFoods: 0, foodsByDataType: ["sr_legacy_food": 1], foodsWithoutNutrients: 0, skippedNutrientIDs: [])
        ), "FDC SR Legacy 2018-04")

        // A failed conversion leaves nothing behind.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("food_nutrient.csv"))
        XCTAssertThrowsError(try FDCBundleImporter.convertToTemporaryFile(bundle: folder, temporaryRoot: root))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1)
    }

    /// The streaming reader must agree with the app's CSV parser at every chunk boundary.
    func testRecordStreamMatchesTheCSVParser() throws {
        let content = "\u{FEFF}\"id\",name , \"note\" \r\n"
            + "1,\"Soup, \"\"hot\"\"\",plain\r\n"
            + "\r\n"
            + "2,\"line one\r\nline two\",  padded value \n"
            + "3,5\" pizza,\"\"\n"
            + "   \n"
            + "4,caf\u{E9} cr\u{E8}me,\"\u{A0}kept\u{A0}\"\n"
            + "5,\u{A0}trimmed\u{A0},\"last, no newline\""
        let url = folder.appendingPathComponent("stream.csv")
        try Data(content.utf8).write(to: url)
        let expected = try CSVParser.parseRecords(content: CSVParser.stripBOM(content), delimiter: ",")
        XCTAssertEqual(expected.count, 6)
        XCTAssertEqual(expected[1], ["1", "Soup, \"hot\"", "plain"])
        for chunkBytes in [16, 17, 19, 23, 31, 64, 1_048_576] {
            var records: [[String]] = []
            try CSVRecordStream.forEachRecord(in: url, chunkBytes: chunkBytes) { records.append(try $0.strings()) }
            XCTAssertEqual(records, expected, "chunk size \(chunkBytes)")
        }

        func failure(_ text: String) -> CSVParseError? {
            try? Data(text.utf8).write(to: url)
            do {
                try CSVRecordStream.forEachRecord(in: url, chunkBytes: 16) { _ = try $0.strings() }
                return nil
            } catch { return error as? CSVParseError }
        }
        XCTAssertEqual(failure("a,\"open\nb,c\n"), .unterminatedQuotedField)
        XCTAssertEqual(failure("a,\"closed\"x,c\n"), .unexpectedCharacterAfterClosingQuote("x"))
        try Data([0x61, 0x2C, 0xFF, 0xFE, 0x0A]).write(to: url)
        XCTAssertThrowsError(try CSVRecordStream.forEachRecord(in: url) { _ = try $0.strings() }) {
            XCTAssertEqual($0 as? CSVParseError, .invalidEncoding)
        }
    }
}
