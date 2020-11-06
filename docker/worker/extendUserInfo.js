/*
Works with __extendedInfo: true
*/
//const notify = require("../../libs/Notify.js")('api','user.hooks.extendUserInfo')
const generalHookResultProcessing = require("../../libs/generalHookResultProcessing")
const merge = require('merge-anything').merge

module.exports = function () {
  return async context => {
    return await generalHookResultProcessing(context, async (item) => {
      if (context.params && context.params.query && context.params.query["__extendedInfo"]){
        context.params.__extendedInfo = context.params.query["__extendedInfo"]
        delete context.params.query["__extendedInfo"]
      }

      if (!context.params.__extendedInfo)
        return context

      if (context.type == "before"){
        var relation = "Client.ActivePlans.ServicePlan"
        if (context.params.__relations)
          context.params.__relations += "," + relation
        else
          context.params.__relations = relation
      }
      else{
        item.permissions =  []

        if (item.Client.ActivePlans !== undefined){
          item.Client.ActivePlans.forEach((activePlan) => {
            item.permissions = merge(item.permissions, activePlan.ServicePlan.permissions)
          })
        }
      }

      return context
    })
  };
};
