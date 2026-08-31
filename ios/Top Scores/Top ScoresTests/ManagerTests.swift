import Foundation
import Testing
@testable import Top_Scores

@MainActor
struct ManagerTests {
    @Test func managerPortrait_usesOriginalImageWithLocalBackgroundRemoval() throws {
        let source = try #require(URL(
            string: "https://sports.bzzoiro.com/img/manager/529/?bg=transparent&size=150"
        ))
        let result = portraitURLForLocalBackgroundRemoval(source)

        #expect(portraitURLNeedsBackgroundRemoval(result))
        #expect(result.absoluteString.contains("bg=transparent") == false)
        #expect(result.absoluteString.contains("size=150"))
    }

    @Test func managerDecodesProfileAndCalculatedPercentages() throws {
        let json = Data(#"""
        {
          "id":"264",
          "name":"Álvaro Arbeloa",
          "country":"Spain",
          "tactical_profile":"attacking",
          "preferred_formation":"4-2-3-1",
          "current_team_id":"6",
          "matches_total":63,
          "wins":40,
          "draws":7,
          "losses":16,
          "win_pct":63.5,
          "draw_pct":11.1,
          "loss_pct":25.4,
          "avg_goals_scored":2.0,
          "avg_goals_conceded":1.16,
          "avg_possession":58.55,
          "clean_sheet_pct":30.2,
          "image_url":"https://sports.bzzoiro.com/img/manager/264/"
        }
        """#.utf8)

        let manager = try JSONDecoder().decode(TeamManager.self, from: json)
        #expect(manager.name == "Álvaro Arbeloa")
        #expect(manager.currentTeamID == "6")
        #expect(manager.drawPercentage == 11.1)
        #expect(manager.lossPercentage == 25.4)
        #expect(PlayerNationalityPresentation.flag(for: manager.country) == "🇪🇸")
    }

    @Test func currentTenureUsesPierreSageCrystalPalaceRecord() throws {
        let json = Data(#"""
        {
          "manager_id":"322",
          "count":2,
          "tenures":[
            {
              "team_id":"14",
              "team_name":"Crystal Palace",
              "date_from":"2026-03-21",
              "date_to":null,
              "matches":14,
              "wins":7,
              "draws":1,
              "losses":6,
              "win_pct":50
            },
            {
              "team_id":"14",
              "team_name":"Crystal Palace",
              "date_from":"2020-01-01",
              "date_to":"2020-06-30",
              "matches":20,
              "wins":10,
              "draws":5,
              "losses":5
            }
          ]
        }
        """#.utf8)

        let career = try JSONDecoder().decode(ManagerCareerResponse.self, from: json)
        let tenure = try #require(career.currentTenure(for: "14"))
        #expect(tenure.matches == 14)
        #expect(tenure.wins == 7)
        #expect(tenure.draws == 1)
        #expect(tenure.losses == 6)
    }

    @Test func previousClubsExcludesCurrentTeamAndRetainsLogoData() throws {
        let json = Data(#"""
        {
          "manager_id":"264",
          "count":3,
          "tenures":[
            {
              "team_id":"6",
              "team_name":"Current FC",
              "team_logo_url":"https://sports.bzzoiro.com/img/team/6/",
              "matches":63,
              "appointment_effect": {
                "window":10,
                "before": {
                  "matches":10,
                  "wins":5,
                  "draws":3,
                  "losses":2,
                  "points":18,
                  "ppm":1.8,
                  "win_pct":50,
                  "goals_for":16,
                  "goals_against":10,
                  "goal_diff":6
                },
                "after": {
                  "matches":4,
                  "wins":3,
                  "draws":0,
                  "losses":1,
                  "points":9,
                  "ppm":2.25,
                  "win_pct":75,
                  "goals_for":11,
                  "goals_against":9,
                  "goal_diff":2,
                  "matches_led_by_manager":4
                },
                "ppm_change":0.45
              }
            },
            {
              "team_id":"57",
              "team_name":"Real Madrid",
              "team_logo_url":"https://sports.bzzoiro.com/img/team/57/",
              "date_from":"2025-01-01",
              "date_to":"2026-06-30",
              "matches":20,
              "wins":12,
              "draws":4,
              "losses":4,
              "win_pct":60.0,
              "points":40,
              "ppm":2.0,
              "goals_for":38,
              "goals_against":19,
              "goal_diff":19
            },
            {
              "team_id":"112",
              "team_name":"Invalid FC",
              "date_from":"2026-04-04",
              "date_to":"2026-02-14",
              "matches":0
            }
          ]
        }
        """#.utf8)

        let career = try JSONDecoder().decode(ManagerCareerResponse.self, from: json)
        let previousClubs = career.previousClubs(excluding: "6")
        #expect(previousClubs.map(\.teamName) == ["Real Madrid"])
        #expect(previousClubs.first?.teamLogoURL?.contains("/img/team/57/") == true)
        #expect(previousClubs.first?.pointsPerMatch == 2.0)

        let effect = career.appointmentEffect(for: "6")
        #expect(effect?.window == 10)
        #expect(effect?.before.pointsPerMatch == 1.8)
        #expect(effect?.after.matchesLedByManager == 4)
        #expect(effect?.pointsPerMatchChange == 0.45)
    }

    @Test func appointmentImpactTrend_reversesOutcomeForGoalsConceded() throws {
        let fewerConceded = try #require(ManagerImpactTrend.compare(
            before: 15,
            after: 13,
            lowerIsBetter: true
        ))
        #expect(fewerConceded.direction == .down)
        #expect(fewerConceded.outcome == .improvement)

        let moreConceded = try #require(ManagerImpactTrend.compare(
            before: 13,
            after: 15,
            lowerIsBetter: true
        ))
        #expect(moreConceded.direction == .up)
        #expect(moreConceded.outcome == .decline)

        let unchanged = try #require(ManagerImpactTrend.compare(before: 10, after: 10))
        #expect(unchanged.direction == .unchanged)
        #expect(unchanged.outcome == .unchanged)
    }
}
