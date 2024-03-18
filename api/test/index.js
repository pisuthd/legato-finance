const chai = require('chai')
const { getTokenPrices } = require("../lib")

const { expect } = chai

describe('#lib', function () {


    // before(function () {
    //     lib = new Lib()
    // })

    it('should get all token prices from CoinGecko success ', async () => {

        const prices = await getTokenPrices() 

        expect(prices.length).to.equal(1)
        expect(prices[0].price > 0.1).to.true
    })

    // it('test dates', async () => {

    //     let currentDate = new Date()

    
    //     currentDate.setUTCHours(0)
    //     currentDate.setUTCMinutes(0)
    //     currentDate.setUTCSeconds(0)
    //     currentDate.setUTCMilliseconds(0)

    //     console.log("previous #1 --> ", currentDate.valueOf())

    //     console.log("previous #2 --> ", currentDate.setDate(currentDate.getDate() - 1))

    //     console.log("previous #3 --> ", currentDate.setDate(currentDate.getDate() - 1))

    //     console.log("previous #4 --> ", currentDate.setDate(currentDate.getDate() - 1))
    //     console.log("previous #5 --> ", currentDate.setDate(currentDate.getDate() - 1))

    //     console.log("previous #6 --> ", currentDate.setDate(currentDate.getDate() - 1))
    //     console.log("previous #7 --> ", currentDate.setDate(currentDate.getDate() - 1))
    //     console.log("previous #8 --> ", currentDate.setDate(currentDate.getDate() - 1))

    //     expect(true).to.true
    // })

})